package Net::EPP::Frame::Command::Withdraw::Domain;

# $Id$
# $HeadURL$
use strict;
use warnings;
use base qw(Net::EPP::Frame::Command);

sub commandNamespace { return ( 'urn:dkhm:params:xml:ns:dkhm-4.2' ); }
sub withdrawNamespace { return ( 'urn:dkhm:params:xml:ns:dkhm-domain-4.2', 'domain' ); }

sub new {
	my ($package, $type) = @_;
	my $self = $package->SUPER::new;
    my $extelm = $self->createElement('extension');
    $self->getNode('epp')->addChild($extelm);
    my $command = $self->getNode('command');
    $command->setNamespace( commandNamespace );
    $command->unbindNode;
    $extelm->addChild($command);
    #$self->getNode('transfer');
    #->setNodeName('withdraw');
    return $self;
}

sub setDomain {
    my ($self, $domain) = @_;
    my $element = $self->getNode('withdraw');
    my $domain_elm = $self->createElement('domain:withdraw');
    $domain_elm->setNamespace( withdrawNamespace );
    $element->appendChild($domain_elm);
    my $name_elm = $self->createElement('domain:name');
    $name_elm->appendText($domain);
    $domain_elm->appendChild($name_elm);
    return 1;
}

1;
