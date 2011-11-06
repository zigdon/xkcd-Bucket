# BUCKET PLUGIN

use BucketBase qw/route say do Log/;
use Data::Dumper;
$Data::Dumper::indent = 1;

sub signals {
  return (qw/*/);
}

sub route {
  my ($package, $sig, $data, $config) = @_;

  &Log("route($sig): ", Dumper($data));

  return 0;
}

