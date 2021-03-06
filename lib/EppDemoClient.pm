package EppDemoClient;
use Mojo::Base 'Mojolicious';

use Net::EPP::Client;
use Net::EPP::Frame::ObjectSpec;
use Net::EPP::Frame::Command;
use Net::EPP::Frame::Command::Login;
use Net::EPP::Frame::Command::Logout;
use Net::EPP::Frame::Command::Check::Domain;
use Net::EPP::Frame::Command::Check::Host;
use Net::EPP::Frame::Command::Create::Domain;
use Net::EPP::Frame::Command::Create::Host;
use Net::EPP::Frame::Command::Delete::Domain;
use Net::EPP::Frame::Command::Delete::Host;
use Net::EPP::Frame::Command::Info::Domain;
use Net::EPP::Frame::Command::Info::Host;
use Net::EPP::Frame::Command::Renew::Domain;
use Net::EPP::Frame::Command::Update::Domain;
use Net::EPP::Frame::Command::Update::Host;
use Net::EPP::Frame::Command::Poll::Ack;
use Net::EPP::Frame::Command::Poll::Req;
use Net::EPP::Frame::Command::Withdraw::Domain;

use Net::IP;
use Time::HiRes;
use Digest::MD5 qw(md5_hex);
use XML::Twig;
use Syntax::Keyword::Try;

# This method will run once at server start
sub startup {
    my $self = shift;

    my $config = $self->plugin('Config');

    # Router
    my $r = $self->routes;

    $self->secrets(['VeryVerySecretSecret01234']);
    $self->sessions->default_expiration(0);

    $self->plugin(AssetPack => {pipes => [qw(Css JavaScript Combine)]});

    $self->asset->process(
        "app.css" => (
            "https://maxcdn.bootstrapcdn.com/bootstrap/3.3.6/css/bootstrap.css",
            "https://maxcdn.bootstrapcdn.com/font-awesome/4.6.3/css/font-awesome.css",
            "prism.css",
        )
    );

    $self->asset->process(
        "app.js" => (
            "https://ajax.googleapis.com/ajax/libs/jquery/1.11.3/jquery.js",
            "https://netdna.bootstrapcdn.com/bootstrap/3.3.6/js/bootstrap.js",
            "prism.js",
            "app.js",
        )
    );

    $self->helper(set_if_can             => \&set_if_can);
    $self->helper(get_login_request      => \&get_login_request);
    $self->helper(get_request_frame      => \&get_request_frame);
    $self->helper(get_logout_request     => \&get_logout_request );
    $self->helper(epp_client             => \&epp_client );
    $self->helper(pretty_print           => \&pretty_print);
    $self->helper(xml_tag                => \&_xml_tag );
    $self->helper(extension_element      => \&_extension_element );
    $self->helper(add_extension_element  => \&_add_extension_element );
    $self->helper(parse_reply            => \&parse_reply);
    $self->helper(commands_from_object   => \&commands_from_object);
    $self->helper(namespace              => \&namespace);
    $self->helper(elements               => \&_elements);
    $self->helper(text_elements          => \&_text_elements);
    $self->helper(text_element_into      => \&_text_element_into);
    $self->helper(generic_param_to_frame => \&_generic_param_to_frame);

    # Normal route to controller
    $r->get('/')->to('client#index');
    $r->get('/login')->to('client#index');
    $r->get('/logout')->to('client#logout');
    $r->post('/login')->to('client#login');
    $r->post('/execute')->to('client#execute');
    $r->get('/execute' => sub{ shift()->redirect_to('/') });

    # Ajax requests
    $r->post('/get_login_xml')->to('ajax#get_login_xml');
    $r->post('/get_request_xml')->to('ajax#get_request_xml');
    $r->post('/get_commands_from_object')->to('ajax#get_commands_from_object');
    $r->post('/get_command_form')->to('ajax#get_command_form');

}

#
# Helper to find element ($tagname) and extract attribute value ($attributename) -or- text content (if $attributename has not been specified)
#
sub _xml_tag {
    my ($self, $epp_frame, $tagname, $attributename) = @_;

    $epp_frame
        or return undef;

    my $element = ($epp_frame->getElementsByTagName($tagname))[0]
        or return undef;

    $attributename
        or return $element->textContent // undef;

    return $element->getAttribute($attributename) // undef;
}

sub _elements {
    my($self, $xml, $tag_name) = @_;
    if ( ! $xml ) { return; }
    my @elements = map { ref($_) eq "ARRAY" ? ( @$_ ) : $_ } $xml->getElementsByTagName($tag_name);
    return @elements;
}

sub _text_elements {
    my($self, $xml, $tag_name) = @_;
    my @elements = $self->elements( $xml, $tag_name );
    my(@texts) = map { UNIVERSAL::can($_, 'textContent')  ? $_->textContent : $_ } @elements;
}

sub _text_element_into {
    my($self, $xml, $tag_name, $dest_hash, $dest_name ) = @_;
    my(@texts) = $self->text_elements( $xml, $tag_name );
    if ( ! @texts ) { return; }

    my $number = "";

    foreach my $text ( @texts ) {

        $dest_hash->{$dest_name.$number} = $text;

        $number ||= 1;
        $number++;
    }
}

sub _extension_element {
    my($self, $xml_frame) = @_;

    my $extension_element = $xml_frame->getNode('extension');
    if ( ! $extension_element ) {
         $extension_element = $xml_frame->createElement('extension');
         $xml_frame->getNode('command')->appendChild($extension_element);
    }

    return $extension_element;
}

sub _add_extension_element {
    my($self, $xml_frame, $element_name, $value, $extension_element) = @_;

    $extension_element //= $self->extension_element($xml_frame);

    if($value) {
        my $element = $xml_frame->createElement($element_name);
        $element->setNamespace( $self->namespace('dkhm') );
        $element->appendText($value);
        $extension_element->appendChild($element);
    }
}

sub _add_ds_extension_element {
    my($frame, $op, $urgent) = @_;

    my $extension = $frame->getNode('extension');
    if ( ! $extension ) {
        $extension = $frame->createElement('extension');
        $frame->getNode('command')->appendChild($extension);
    }

    my $update = $frame->getNode('secDNS:update');
    if ( ! $update ) {
        $update = $frame->createElement('update');
        $update->setNamespace( 'urn:ietf:params:xml:ns:secDNS-1.1', 'secDNS' );

        if ( $urgent ) {
            $update->setAttribute( 'urgent' , 'true' );
        }
        $extension->appendChild($update);
    }

    my $op_element = $frame->getNode("secDNS:${op}");
    if ( ! $op_element ) {
        $op_element = $frame->createElement("secDNS:${op}");
        $update->appendChild($op_element);
    }

    return $op_element;
}

# Central storage of connections to the EPP server. The connection id
# is stored in session and EPP connections will live between browser
# requests.
my %connections;

sub add_connection {
    my ($self, $id, $connection) = @_;
    $connections{$id} = $connection;
}

sub get_connection {
    my ($self, $id) = @_;
    return $connections{$id};
}

sub expire_connection {
    my ($self, $id) = @_;
    if($connections{$id}) {
        try {
            $connections{$id}->disconnect;
        } catch($err) {

        }
        delete $connections{$id};
    }
}

sub set_if_can {
    my($self, $frame, $func, @args) = @_;
    return unless @args;
    return unless UNIVERSAL::can($frame, $func);
    $frame->$func(@args);
}

sub get_login_request {
    my ($self, $username, $password) = @_;

    my $login = Net::EPP::Frame::Command::Login->new;

    $login->clID->appendText($username);
    $login->pw->appendText($password);
    $login->lang->appendText(    'en'  );
    $login->version->appendText( '1.0' );
    $login->clTRID->appendText( md5_hex(Time::HiRes::time().$$) ); # set the client transaction ID:

    foreach my $v (qw(domain host contact)){
        my($type, $xmlns, $schemaLocation) = Net::EPP::Frame::ObjectSpec->spec($v);
        my $obj = $login->createElement('objURI');
        $obj->appendText($xmlns);
        $login->svcs->appendChild($obj);
    }

    my $svcs_ext;
    foreach my $xmlns_name (qw(xmlns.secDNS xmlns.dkhm)){
        my $xmlns = $self->param($xmlns_name);
        if ( @{ $self->every_param($xmlns_name) } ) {
            $self->app->log->info(sprintf('Set session %s => %s', $xmlns_name, $xmlns//"<undef>"));
            $self->session($xmlns_name => $xmlns);
            next unless $xmlns;
        }
        else {
            $xmlns = $self->session($xmlns_name) || next;
        }
        my $obj = $login->createElement('extURI');
        $obj->appendText($xmlns);
        $svcs_ext //= $login->createElement('svcExtension');
        $svcs_ext->appendChild($obj);
    }
    $login->svcs->appendChild($svcs_ext) if $svcs_ext;

    return $login;
}

sub get_request_frame {
    my ($self) = @_;

    my $command = $self->param('command');  # f.ex. create/update
    my $object  = $self->param('object');   # f.ex. host/domain/poll

    my $cmd = ucfirst($command) . '::' . ucfirst($object);
    # For poll the object and command order is reversed
    if ( $object eq 'poll' ) {
        $cmd = ucfirst($object) . '::' . ucfirst($command);
    }

    my $frame_name = 'Net::EPP::Frame::Command::' . $cmd;

    $self->app->log->info("get_request_frame $object / $command => $cmd  => $frame_name");

    my $frame = $frame_name->new;

    #
    # Generic transfer
    # f.ex. param('domain')
    # into $frame->setDomain($value) or $frame->addDomain($value) [if frame has method],
    # also sets session('domain' => $value)
    #
    $self->generic_param_to_frame('domain',               $frame, 'setDomain', 'addDomain');
    $self->generic_param_to_frame('curExpDate',           $frame, 'setCurExpDate');
    $self->generic_param_to_frame('period',               $frame, 'setPeriod');
    $self->generic_param_to_frame('host',                 $frame, 'setHost', 'addHost');
    $self->generic_param_to_frame('new_host',             $frame, 'chgName');
    $self->generic_param_to_frame('userid',               $frame, 'setContact', 'addContact');
    $self->generic_param_to_frame('change_registrant',    $frame, 'chgRegistrant');
    $self->generic_param_to_frame('msgID',                $frame, 'setMsgID');

    my($domain_create_el) = $frame->getElementsByTagName('domain:create');
    if( $domain_create_el ) {
        my $nameserver_names     = $self->every_param('new_nameserver_name');
        my $nameserver_el = $frame->createElement('domain:ns');
        foreach my $nameserver_name ( @$nameserver_names ) {
            next unless $nameserver_name;
            my $el = $frame->createElement('domain:hostObj');
            $el->appendText($nameserver_name);
            $nameserver_el->appendChild($el);
        }
        $domain_create_el->appendChild($nameserver_el);

        my $registrant = $self->param('new_registrant');
        if ($registrant) {
            my $el = $frame->createElement('domain:registrant');
            $el->appendText($registrant);
            $domain_create_el->appendChild($el);
        }

        my $contact_types      = $self->every_param('new_contact_type');
        my $contact_userids    = $self->every_param('new_contact_userid');
        while ( @$contact_types ) {
            my $contact_type      = shift @$contact_types;
            my $contact_userid    = shift @$contact_userids;
            next unless $contact_type || $contact_userid;

            my $el = $frame->createElement('domain:contact');
            $el->appendText($contact_userid);
            $el->setAttribute( 'type', $contact_type );
            $domain_create_el->appendChild($el);
        }


        my $keytags      = $self->every_param('new_ds_keytag');
        my $algorithms   = $self->every_param('new_ds_algorithm');
        my $digest_types = $self->every_param('new_ds_digest_type');
        my $digests      = $self->every_param('new_ds_digest');
        while ( @{$keytags} ) {
            my $keytag       = shift @{$keytags};
            my $algorithm    = shift @{$algorithms};
            my $digest_type  = shift @{$digest_types};
            my $digest       = shift @{$digests};
            next unless $keytag || $algorithm || $digest_type || $digest;

            my $extension = $self->extension_element($frame);

            my $create = $frame->getNode('secDNS:create');
            if ( ! $create ) {
                $create = $frame->createElement('create');
                $create->setNamespace( $self->namespace('secDNS') );
                $extension->appendChild($create);
            }

            my $data_element = $frame->createElement('secDNS:dsData');

            my $keytag_element = $frame->createElement('secDNS:keyTag');
            $keytag_element->appendText( $keytag );
            $data_element->appendChild($keytag_element);

            my $algorithm_element = $frame->createElement('secDNS:alg');
            $algorithm_element->appendText( $algorithm );
            $data_element->appendChild($algorithm_element);

            my $digest_type_element = $frame->createElement('secDNS:digestType');
            $digest_type_element->appendText( $digest_type );
            $data_element->appendChild($digest_type_element);

            my $digest_element = $frame->createElement('secDNS:digest');
            $digest_element->appendText( $digest );
            $data_element->appendChild($digest_element);

            $create->appendChild($data_element);
        }
        my $orderconfirmationtoken = $self->param('orderconfirmationtoken');
        if ($orderconfirmationtoken) {
            my $extension = $self->extension_element($frame);
            my $token_el = $frame->createElement('dkhm:orderconfirmationToken');
            $token_el->setNamespace( $self->namespace('dkhm') );
            $token_el->appendText($orderconfirmationtoken);
            $extension->appendChild($token_el);
        }
        $self->session(
            registrant => $registrant,
        );
    }


    my $addrs = $self->every_param('addr');
    foreach my $addr (@${addrs}) {
        next unless $addr;
        my $ip = Net::IP->new($addr);
        my $set_addr = { 'ip' => $addr, 'version' => 'v' . ($ip ? $ip->version : '4') };
        $self->set_if_can($frame, 'setAddr', $set_addr);
    }

    my $add_addrs = $self->every_param('add_addr');
    foreach my $addr (@${add_addrs}) {
        if($addr) {
            my $ip = Net::IP->new($addr);
            $frame->addAddr({ 'ip' => $addr, 'version' => 'v' . ($ip ? $ip->version : '4') });
        } else {
            my $add_addr = $frame->getElementsByLocalName('host:add')->shift;
            $frame->getNode('host:update')->removeChild($add_addr);
        }
    }

    my $remove_addrs = $self->every_param('remove_addr');
    foreach my $addr (@${remove_addrs}) {
        if($addr) {
            my $ip = Net::IP->new($addr);
            $frame->remAddr({ 'ip' => $addr, 'version' => 'v' . ($ip ? $ip->version : '4') });
        } else {
            my $remove_addr = $frame->getElementsByLocalName('host:rem')->shift;
            $frame->getNode('host:update')->removeChild($remove_addr);
        }
    }

    my $requestedNsAdmin = $self->param('requestedNsAdmin');
    if($requestedNsAdmin) {

        my $extension = $self->extension_element($frame);

        my $nsa_element = $frame->createElement('dkhm:requestedNsAdmin');
        $nsa_element->setNamespace( $self->namespace('dkhm') );
        $nsa_element->appendText($requestedNsAdmin);

        $extension->appendChild($nsa_element);

        $self->session(requestedNsAdmin => $requestedNsAdmin);
    }

    if( $cmd eq 'Poll::Ack') {
        $frame->setMsgID($self->param('msgID'));
    }

    if($object eq 'contact') {

        my $addr = {
            street => $self->every_param('contact.street'),
            city   => $self->param('contact.city'),
            pc     => $self->param('contact.zipcode'),
            cc     => $self->param('contact.country'),
        };

        if ($command eq 'create') {
            $frame->setContact( $self->param('contact.userid') // 'auto' );

            $frame->addPostalInfo('loc', $self->param('contact.name'), $self->param('contact.org'), $addr);
            if (my $voice = $self->param('contact.voice')) {
                $frame->setVoice($voice);
            }
            if (my $fax = $self->param('contact.fax')) {
                $frame->setFax($fax);
            }
            if (my $email = $self->param('contact.email') ) {
                $frame->setEmail($email);
            }

            if (my $usertype = $self->param('contact.usertype')) {
                $self->add_extension_element($frame, 'dkhm:userType', $usertype);
            }

            if (my $cvr = $self->param('contact.cvr')) {
                $self->add_extension_element($frame, 'dkhm:CVR', $cvr);
            }

            if (my $pnumber = $self->param('contact.pnumber')) {
                $self->add_extension_element($frame, 'dkhm:pnumber', $pnumber);
            }

        }
        elsif ($command eq 'update') {
            # $frame->setContact( $self->param('contact.userid') );

            if($addr->{street}[0]) {
                $frame->chgPostalInfo('loc', $self->param('contact.name'), $self->param('contact.org'), $addr);
            } elsif ($self->param('contact.name')) {
                $frame->chgPostalInfo('loc', $self->param('contact.name'), $self->param('contact.org'), undef);
                my $addrnode = $frame->getNode('contact:addr');
                $frame->getNode('contact:postalInfo')->removeChild($addrnode);
            }

            if(!$self->param('contact.name') && $addr->{street}[0]) {
                my $namenode = $frame->getNode('contact:name');
                $frame->getNode('contact:postalInfo')->removeChild($namenode);
            }


            #FIXME: Replace 3 if statements below with the 3 lines below
            # when and if patch sent to Net::EPP is accepted.
            #$frame->chgVoice($self->param('contact.voice')) if $self->param('contact.voice');
            #$frame->chgFax($self->param('contact.fax')) if $self->param('contact.fax');
            #$frame->chgEmail($self->param('contact.email')) if $self->param('contact.email');
            if ($self->param('contact.voice')) {
                my $el = $frame->createElement('contact:voice');
                $el->appendText($self->param('contact.voice'));
                $frame->getElementsByLocalName('contact:chg')->shift->appendChild($el);
            }
            if ($self->param('contact.fax')) {
                my $el = $frame->createElement('contact:fax');
                $el->appendText($self->param('contact.fax'));
                $frame->getElementsByLocalName('contact:chg')->shift->appendChild($el);
            }
            if ($self->param('contact.email')) {
                my $el = $frame->createElement('contact:email');
                $el->appendText($self->param('contact.email'));
                $frame->getElementsByLocalName('contact:chg')->shift->appendChild($el);
            }

            my $addnode = $frame->getNode('contact:add');
            $frame->getNode('contact:update')->removeChild($addnode);

            my $remnode = $frame->getNode('contact:rem');
            $frame->getNode('contact:update')->removeChild($remnode);

            my $email2 = $self->param('contact.email2');
            my $mobilephone = $self->param('contact.mobilephone');
            my $cvr = $self->param('contact.cvr');
            my $pnumber = $self->param('contact.pnumber');
            my $usertype = $self->param('contact.usertype');
            my $ean = $self->param('contact.ean');
            if($email2 || $mobilephone || $cvr || $pnumber || $usertype || $ean) {
                $self->add_extension_element($frame, 'dkhm:pnumber', $pnumber);
                $self->add_extension_element($frame, 'dkhm:CVR', $cvr);
                $self->add_extension_element($frame, 'dkhm:mobilephone', $mobilephone);
                $self->add_extension_element($frame, 'dkhm:secondaryEmail', $email2);
                $self->add_extension_element($frame, 'dkhm:EAN', $ean);
                $self->add_extension_element($frame, 'dkhm:userType', $usertype);
            }

        }

        my ($street1, $street2, $street3) = @{$self->every_param('contact.street')};

        $self->session(
            'contact.street'      => $street1,
            'contact.street2'     => $street2,
            'contact.street3'     => $street3,
            'contact.city'        => $self->param('contact.city'),
            'contact.zipcode'     => $self->param('contact.zipcode'),
            'contact.country'     => $self->param('contact.country'),
            'contact.name'        => $self->param('contact.name'),
            'contact.org'         => $self->param('contact.org'),
            'contact.voice'       => $self->param('contact.voice'),
            'contact.mobilephone' => $self->param('contact.mobilephone'),
            'contact.fax'         => $self->param('contact.fax'),
            'contact.email'       => $self->param('contact.email'),
            'contact.email2'      => $self->param('contact.email2'),
            'contact.usertype'    => $self->param('contact.usertype'),
            'contact.cvr'         => $self->param('contact.cvr'),
            'contact.ean'         => $self->param('contact.ean'),
            'contact.pnumber'     => $self->param('contact.pnumber'),
            'contact.userid'      => $self->param('contact.userid'),
        );
    }


    my $remove_all   = $self->param('rem_all_dsrecords');
    if ( $remove_all ) {
        my $op_element   = _add_ds_extension_element($frame, 'rem', 1);
        my $data_element = $frame->createElement('secDNS:all');
        $data_element->appendText( "true" );
        $op_element->appendChild($data_element);
    }

    foreach my $op ( 'rem', 'add' ) {

        my $keytags      = $self->every_param($op.'_ds_keytag');
        my $algorithms   = $self->every_param($op.'_ds_algorithm');
        my $digest_types = $self->every_param($op.'_ds_digest_type');
        my $digests      = $self->every_param($op.'_ds_digest');
        while ( @$keytags ) {
            my $keytag       = shift @$keytags;
            my $algorithm    = shift @$algorithms;
            my $digest_type  = shift @$digest_types;
            my $digest       = shift @$digests;
            next unless $keytag || $algorithm || $digest_type || $digest;

            my $extension = $self->extension_element($frame);

            my $update = $frame->getNode('secDNS:update');
            if ( ! $update ) {
                $update = $frame->createElement('update');
                $update->setNamespace( $self->namespace('secDNS') );
                $extension->appendChild($update);
            }

            my $op_element = $frame->getNode("secDNS:${op}");
            if ( ! $op_element ) {
                $op_element = $frame->createElement("secDNS:${op}");
                $update->appendChild($op_element);
            }


            my $data_element = $frame->createElement('secDNS:dsData');

            my $keytag_element = $frame->createElement('secDNS:keyTag');
            $keytag_element->appendText( $keytag );
            $data_element->appendChild($keytag_element);

            my $algorithm_element = $frame->createElement('secDNS:alg');
            $algorithm_element->appendText( $algorithm );
            $data_element->appendChild($algorithm_element);

            my $digest_type_element = $frame->createElement('secDNS:digestType');
            $digest_type_element->appendText( $digest_type );
            $data_element->appendChild($digest_type_element);

            my $digest_element = $frame->createElement('secDNS:digest');
            $digest_element->appendText( $digest );
            $data_element->appendChild($digest_element);


            $op_element->appendChild($data_element);
        }


        my $nameserver_names     = $self->every_param($op.'_nameserver_name');
        my $nameserver_addrs     = $self->every_param($op.'_nameserver_addr');
        my @ns_data;
        while ( @$nameserver_names ) {
            my $nameserver_name     = shift @$nameserver_names;
            my $nameserver_addrs    = shift @$nameserver_addrs;
            next unless $nameserver_name;
            my @addrs = map { { addr => $_, version => (/^\d+\.\d+\.\d+\.\d+$/ ? 'v4' : 'v6') } } split /[^a-z0-9:.]+/, $nameserver_addrs;

            push @ns_data, @addrs ? { name => $nameserver_name, addrs => \@addrs } : $nameserver_name;
        }
        if ( @ns_data ) {
            ## use Data::Dumper; warn "=== NAMESERVER $op $nameserver_name $nameserver_addrs ==> ".Dumper(\@ns_data)." ===\n";
            # Use $frame->addNS() or $frame->remNS() to insert into frame.
            my $call = $op."NS";
            $frame->$call( @ns_data );
        }

        my $contact_types      = $self->every_param($op.'_contact_type');
        my $contact_userids    = $self->every_param($op.'_contact_userid');
        while ( @$contact_types ) {
            my $contact_type      = shift @$contact_types;
            my $contact_userid    = shift @$contact_userids;
            next unless $contact_type || $contact_userid;

            # Use $frame->addContact() or $frame->remContact() to insert into frame.
            my $call = $op."Contact";
            $frame->$call( $contact_type, $contact_userid );
        }


        my $status_types      = $self->every_param($op.'_status_type');
        my $status_infos      = $self->every_param($op.'_status_info');
        while ( @$status_types ) {
            my $status_type      = shift @$status_types;
            my $status_info      = shift @$status_infos;
            next unless $status_type || $status_info;

            # Use $frame->addStatus() or $frame->remStatus() to insert into frame. remStatus() does not use $status_info
            my $call = $op."Status";
            $frame->$call( $status_type, $status_info );
        }

    }

    my $authinfo_type = $self->param('authinfo_type');
    my $authinfo_pw   = $self->param('authinfo_pw');
    if ( defined $authinfo_type ) {
        my %map = (
            generate => 'auto',
            clear    => '',
            # Perhaps add alternative clear option where authInfoChgType element <domain:null/> is passed instead of <domain:pw/>
            use      => $authinfo_pw,
        );
        $authinfo_pw = $map{ $authinfo_type };
    }
    if ( defined $authinfo_pw ) {
        $self->set_if_can($frame, 'chgAuthInfo', $authinfo_pw );
        $self->set_if_can($frame, 'setAuthInfo', $authinfo_pw );
        $self->session(authinfo_pw => $authinfo_pw);
    }
    $self->generic_param_to_frame('contact.new_password', $frame, 'chgAuthInfo');   # Also see param authinfo_pw, above

    # Delete date for domain delete
    if ( my $del_date = $self->param('delDate') ) {
        $self->add_extension_element($frame, 'dkhm:delDate', $del_date);
        $self->session(delDate => $del_date);
    }

    foreach my $xmlns_name (qw(xmlns.secDNS xmlns.dkhm)){
        next unless @{ $self->every_param($xmlns_name) };
        my $ns = $self->param($xmlns_name);
        $self->session($xmlns_name => $ns);
    }

    # create domain
    if (my $auto_renew = $self->param('auto_renew')) {
        $self->add_extension_element($frame, 'dkhm:autoRenew', $auto_renew);
        $self->session(auto_renew => $auto_renew);
    }

    my $oldid = $frame->getNode('clTRID');
    $frame->getNode('command')->removeChild($oldid);

    my $transactionid = $frame->createElement('clTRID');
    $transactionid->appendText( md5_hex(Time::HiRes::time().$$) );
    $frame->getNode('command')->appendChild($transactionid);

    $self->app->log->info("Frame is $frame_name : $frame");

    return $frame;
}

sub get_logout_request {
    my ($self) = @_;
    my $logout = Net::EPP::Frame::Command::Logout->new;
    $logout->clTRID->appendText( md5_hex(Time::HiRes::time().$$) );
    return $logout;
}

sub epp_client {
    my ($self, $hostname, $port) = @_;

    my $epp = Net::EPP::Client->new(
        host       => $hostname,
        port       => $port,
        ssl        => 1,
        dom        => undef,
        frames     => 1,
    ) or die "failed to connec to epp server $hostname:$port $@";

    return $epp;

}

sub pretty_print {
    my ($self, $epp_frame) = @_;

    my $xml_parser = XML::Twig->new( pretty_print => 'record');
    $xml_parser->parse($epp_frame->toString);

    return $xml_parser->sprint;
}

sub parse_reply {
    my ($self, $epp_frame) = @_;

    my $reply = {
        xml            => $self->pretty_print($epp_frame),
        code           => $self->xml_tag($epp_frame, 'result', 'code') //
                          2400,
        msg            => $self->xml_tag($epp_frame, 'msg') //
                          ($epp_frame||'-') =~ s/<.*?>//gr,
    };

    if ( my $svtrid = $self->xml_tag($epp_frame, 'svTRID') ) {
        $reply->{transaction_id} = $svtrid;
    }

    if ( my $reason =
            $self->xml_tag($epp_frame, 'domain:reason') //
            $self->xml_tag($epp_frame, 'host:reason') //
            $self->xml_tag($epp_frame, 'contact:reason')
    ) {
        $reply->{reason} = $reason;
    }

    if ( my $domain = $self->xml_tag($epp_frame, 'domain:name') ) {
        $reply->{domain} = $domain;
    }
    if ( my $host = $self->xml_tag($epp_frame, 'host:name') ) {
        $reply->{host} = $host;
    }
    if ( my $contactid = $self->xml_tag($epp_frame, 'contact:id') ) {
        $reply->{id} = $contactid;
    }

    if ( my $avail =
            $self->xml_tag($epp_frame, 'domain:name', 'avail') //
            $self->xml_tag($epp_frame, 'host:name', 'avail') //
            $self->xml_tag($epp_frame, 'contact:id', 'avail')
    ) {
        $reply->{avail} = $avail;
    }

    my $host_element = ($epp_frame->getElementsByTagName('host:infData'));
    if($host_element) {
        my $info = ( $reply->{host_data} //= {} );

        $self->text_element_into( $epp_frame, 'host:name',   $info, 'name'   );
        $self->text_element_into( $epp_frame, 'host:roid',   $info, 'roid' );

        my $status = "status";
        foreach my $ele ( $self->elements( $epp_frame, 'host:status' ) ) {
            my $s = $ele->{"s"};
            $info->{ $status } = $s;
            $status .= " ";  # A new key, but space is not visible
        }

        my $addr = "addr";
        foreach my $ele ( $self->elements( $epp_frame, 'host:addr' ) ) {
            $info->{ $addr } = $ele->textContent . " (". $ele->{"ip"} . ")";
            $addr .= " ";  # A new key, but space is not visible
        }

        $self->text_element_into( $epp_frame, 'host:clID',     $info, 'clID' );
        $self->text_element_into( $epp_frame, 'host:crID',     $info, 'crID' );
        $self->text_element_into( $epp_frame, 'host:crDate',   $info, 'crDate' );

    }

    my($domain_element) = $self->elements( $epp_frame, 'domain:infData');
    if($domain_element) {
        my $info = ( $reply->{domain_data} //= {} );

        $self->text_element_into( $epp_frame, 'domain:name',   $info, 'name'   );
        $self->text_element_into( $epp_frame, 'domain:roid',   $info, 'roid' );

        #  <domain:status s="serverDeleteProhibited"/>
        my $status = "status";
        foreach my $ele ( $self->elements( $epp_frame, 'domain:status' ) ) {
            my $s = $ele->{"s"};
            $info->{ $status } = $s;
            $status .= " "; # A new key, but space is not visible
        }

        $self->text_element_into( $epp_frame, 'domain:registrant', $info, 'registrant' );

        foreach my $ele ( $self->elements( $epp_frame, 'domain:contact' ) ) {
            my $type = $ele->getAttribute("type");
            my $userid = $ele->textContent;
            $info->{ $type } = $userid;
        }

        $self->text_element_into( $epp_frame, 'domain:hostObj',    $info, 'ns' );
        $self->text_element_into( $epp_frame, 'domain:host',       $info, 'host' );
        $self->text_element_into( $epp_frame, 'domain:clID',       $info, 'clID' );
        $self->text_element_into( $epp_frame, 'domain:crID',       $info, 'crID' );
        $self->text_element_into( $epp_frame, 'domain:crDate',     $info, 'crDate' );
        $self->text_element_into( $epp_frame, 'domain:exDate',     $info, 'exDate' );

    }

    my($contact_element) = $self->elements( $epp_frame, 'contact:infData');
    if($contact_element) {
        my $info = ( $reply->{contact_data} //= {} );

        $self->text_element_into( $epp_frame, 'contact:id',     $info, 'id'   );
        $self->text_element_into( $epp_frame, 'contact:roid',   $info, 'roid' );
        $self->text_element_into( $epp_frame, 'contact:org',    $info, 'org'  );
        $self->text_element_into( $epp_frame, 'contact:name',   $info, 'name' );
        $self->text_element_into( $epp_frame, 'contact:street', $info, 'street' );
        $self->text_element_into( $epp_frame, 'contact:city',   $info, 'city' );
        $self->text_element_into( $epp_frame, 'contact:pc',     $info, 'pc' );
        $self->text_element_into( $epp_frame, 'contact:cc',     $info, 'cc' );
        $self->text_element_into( $epp_frame, 'contact:voice',  $info, 'voice' );
        $self->text_element_into( $epp_frame, 'contact:fax',    $info, 'fax' );
        $self->text_element_into( $epp_frame, 'contact:email',  $info, 'email' );
        $self->text_element_into( $epp_frame, 'contact:clID',   $info, 'clID' );
        $self->text_element_into( $epp_frame, 'contact:crID',   $info, 'crID' );
        $self->text_element_into( $epp_frame, 'contact:crDate', $info, 'crDate' );

        #  <contact:status s="serverDeleteProhibited"/>
        my $status = "status";
        foreach my $ele ( $self->elements( $epp_frame, 'contact:status' ) ) {
            my $s = $ele->{"s"};
            $info->{ $status } = $s;
            $status .= " ";
        }
    }

    my $contact_created_element = ($epp_frame->getElementsByTagName('contact:creData'))[0];
    if($contact_created_element) {
        my $info = ( $reply->{contact_data} //= {} );
        $self->text_element_into( $epp_frame, 'contact:id',     $info, 'id' );
        $self->text_element_into( $epp_frame, 'contact:crDate', $info, 'crDate' );
    }

    my $domain_created_element = ($epp_frame->getElementsByTagName('domain:creData'))[0];
    if($domain_created_element) {
        my $info = ( $reply->{domain_data} //= {} );
        $self->text_element_into( $epp_frame, 'domain:name',   $info, 'name' );
        $self->text_element_into( $epp_frame, 'domain:crDate', $info, 'crDate' );
        $self->text_element_into( $epp_frame, 'domain:exDate', $info, 'exDate' );
    }

    my $host_created_element = ($epp_frame->getElementsByTagName('host:creData'))[0];
    if($host_created_element) {
        my $info = ( $reply->{host_data} //= {} );
        $self->text_element_into( $epp_frame, 'host:name',   $info, 'name' );
        $self->text_element_into( $epp_frame, 'host:crDate', $info, 'crDate' );
    }

    my $msgq_element = ($epp_frame->getElementsByTagName('msgQ'))[0];
    if($msgq_element) {
        my $info = ( $reply->{msgQ} //= {} );
        $info->{count} = $msgq_element->getAttribute("count");
        $info->{id}    = $msgq_element->getAttribute("id");
        my $message_element = ($msgq_element->getElementsByTagName('msg'))[0];
        if($message_element) {
            $info->{msg} = $message_element->textContent;
        }
    }

    my $extension_element = ($epp_frame->getElementsByTagName('extension'))[0];
    if($extension_element) {
        my $info = ( $reply->{extension} //= {} );
        $self->text_element_into( $epp_frame, 'dkhm:mobilephone', $info, 'dkhm:mobilephone' );
        $self->text_element_into( $epp_frame, 'dkhm:secondaryEmail', $info, 'dkhm:secondaryEmail' );
        $self->text_element_into( $epp_frame, 'dkhm:contact_validated', $info, 'dkhm:contact_validated' );
        $self->text_element_into( $epp_frame, 'dkhm:domain_confirmed', $info, 'dkhm:domain_confirmed' );
        $self->text_element_into( $epp_frame, 'dkhm:registrant_validated', $info, 'dkhm:registrant_validated' );
        $self->text_element_into( $epp_frame, 'dkhm:risk_assessment', $info, 'dkhm:risk_assessment' );

        foreach my $ele ( $self->elements( $epp_frame, 'dkhm:domainAdvisory' ) ) {
            my $advisory = $ele->getAttribute("advisory");
            my $domain   = $ele->getAttribute("domain");
            my $date     = $ele->getAttribute("date");
            $info->{ "Advisory: $advisory" } = join ' / ', $domain, $date//();
        }
    }

    my($svc_menu) = $self->elements( $epp_frame, 'svcMenu');
    if ( $svc_menu ) {
        foreach my $ele ( $self->elements( $svc_menu, 'extURI' ) ) {
            my $extURI = $ele->textContent;
            my $name = $extURI =~ /:(\w+)-[.0-9]+$/ && $1;
            next unless $name;
            my $nsname = "xmlns.${name}";
            my $old = $self->session($nsname);
            if ( ! $old ) {
                $self->app->log->info(sprintf('Setting session %s to "%s"', $nsname, $extURI));
                $self->session($nsname => $extURI);
            }
            elsif ( $old ne $extURI ) {
                $self->app->log->info(sprintf('Session %s remains "%s" (not changing to "%s")', $nsname, $old, $extURI));
            }
            else {
                $self->app->log->info(sprintf('Session %s remains "%s"', $nsname, $old));
            }
        }
    }


    return $reply;
}

sub commands_from_object {
    my ($self, $object) = @_;

    my @values;

    if ($object eq 'host') {
        @values = ['check', 'create', 'delete', 'info', 'update'];
    } elsif ($object eq 'domain') {
        @values = ['check', 'create', 'delete', 'info', 'renew', 'update', 'withdraw'];
    } elsif ($object eq 'contact') {
        @values = ['check', 'create', 'info', 'update'];
    } elsif ($object eq 'poll') {
        @values = ['req', 'ack' ];
    }

    return @values;
}

#
# Calling with 'dkhm' f.ex. returns ('urn:dkhm:params:xml:ns:dkhm-2.0', 'dkhm')
#
sub namespace {
    my($self, $short) = @_;
    my $name = "xmlns.${short}";
    my $ns = $self->param($name) || $self->session($name);
    return( $ns, $short );
}

# Generic transfer f.ex. param('domain') into $frame->setDomain($value) or $frame->addDomain($value) [if frame has method], also sets session('domain' => $value)
sub _generic_param_to_frame {
    my($self, $param_name, $frame, @set_functions) = @_;
    my $values = $self->every_param($param_name);
    foreach my $value ( @$values ) {
        next unless $value;
        foreach my $method ( @set_functions ) {
            $self->set_if_can($frame, $method, $value);
        }
        # Store only last value in session. Can we handle @$values in session instead ?
        $self->session($param_name => $value);
    }
}

1;
