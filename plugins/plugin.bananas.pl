# BUCKET PLUGIN

use BucketBase qw/say config/;

sub signals {
    return (qw/on_public/);
}

sub settings {
    return ( bananas_chance => [ p => 0.02 ] );
}

sub route {
    my ( $package, $sig, $data ) = @_;

    if ( &config("bananas_chance")
        and rand(100) < &config("bananas_chance") ) {
        &say( $data->{chl} => "Bananas!" );
    }

    return 0;
}
