#!/usr/bin/perl -w

package BucketBase;
require Exporter;
@ISA = qw(Exporter);

# utility functions exposed from the main bucket code
@EXPORT_OK = qw(Log Report say do config save yield post);

# plugin definition methods
push @EXPORT_OK, qw(signals commands route);

# make the following subs available for plugins
foreach my $subname (qw/Log Report say do config save/) {
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
