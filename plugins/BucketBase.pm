#!/usr/bin/perl -w

package BucketBase;
require Exporter;
@ISA = qw(Exporter);
@EXPORT_OK = qw(Log Report say do route signals);

sub signals {
  return ();
}

sub route {
  my ($package, $sig, $data, $config) = @_;

  ::Log("Route not implemented in ". (caller)[1]);
}

# make the following subs available for plugins
foreach my $subname (qw/Log Report say do/) {
  eval "sub $subname { ::$subname(\@_); }";
}

1;
