# BUCKET PLUGIN

use BucketBase qw/Log config/;
use Data::Dumper;
$Data::Dumper::indent = 1;

sub signals {
    return (qw/on_msg on_public/);
}

sub route {
    my ( $package, $sig, $data ) = @_;

    # anything that comes here should be processed the same way
    &sub_siri($data);

    return 0;
}

sub sub_siri {
    my ($data) = @_;

    return if $data->{msg} =~ /^(?:un)?load plugin siri$/;
    my $nick = &config("nick");
    $data->{msg} =~ s/\bsiri\b/$nick/ig;
    if ( lc $data->{to} eq 'siri' ) {
        $data->{addressed} = 1;
        $data->{to}        = $nick;
    }

    if ( $data->{msg} =~ s/^siri[:,]\s*|,\s+siri\W+$//i ) {
        $data->{addressed} = 1;
    }
}

