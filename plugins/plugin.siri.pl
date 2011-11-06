# BUCKET PLUGIN

use BucketBase qw/Log/;
use Data::Dumper;
$Data::Dumper::indent = 1;

sub signals {
  return (qw/on_msg on_public/);
}

sub route {
  my ($package, $sig, $data, $config) = @_;

  # anything that comes here should be processed the same way
  &sub_siri($data, $config);

  return 0;
}


sub sub_siri {
  my ($data, $config) = @_;

  return if $data->{msg} =~ /^(?:un)?load plugin siri$/;
  $data->{msg} =~ s/\bsiri\b/$config->{nick}/ig;
}

