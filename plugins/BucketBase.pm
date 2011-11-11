#!/usr/bin/perl -w

package BucketBase;
require Exporter;
@ISA = qw(Exporter);

# utility functions exposed from the main bucket code
my @repeated = qw/Log Report say do config save talking cached_reply sql s/;
push @EXPORT_OK, @repeated;
@EXPORT_OK = qw(yield post);

# plugin definition methods
push @EXPORT_OK, qw(signals commands route);

# make the following subs available for plugins
foreach my $subname (@repeated) {
    eval "sub $subname { ::$subname(\@_); }";
}

sub yield {
    POE::Kernel->yield(@_);
}

sub post {
    POE::Kernel->post(@_);
}

sub signals {
    return ();
}

sub commands {
    return ();
}

sub route {
    my ( $package, $sig, $data, $config ) = @_;

    ::Log( "Route not implemented in " . (caller)[1] );
}

1;
