# BUCKET PLUGIN

use BucketBase qw/do config lookup talking Report/;
my %gagged;

sub signals {
    return (qw/on_public say do/);
}

sub settings {
    return (
        gagged_factoid => [ s => 'fidget' ],
        gagged_resist  => [ p => 1 ],
    );
}

sub commands {
    return (
        {
            label     => 'gag',
            addressed => 0,
            operator  => 1,
            editable  => 0,
            re        => qr/^gags $nick\W*$/i,
            callback  => \&shush,
        },
        {
            label     => 'release',
            addressed => 0,
            operator  => 1,
            editable  => 0,
            re        => qr/^releases $nick\W*$/i,
            callback  => \&free,
        },
    );
}

sub route {
    my ( $package, $sig, $data ) = @_;

    if ( $sig eq 'on_public' ) {
        if (    $gagged{$data->{chl}}
            and &config("gagged_resist")
            and rand(100) < &config("gagged_resist") )
        {
            &lookup( chl => $data->{chl}, msg => &config("gagged_factoid") );
        }

        if ( $gagged{$data->{chl}} and $data->{addressed} and $data->{op} ) {
            $gagged{$data->{chl}} = 0;
            &talking( $data->{chl}, -1 );
            Report( "$data->{who} removed gag in $data->{chl} by addressing" );
        }

        return 0;
    }

    # stop all processing if we're gagged.
    if ( $gagged{$data->{chl}} ) {
        return -1;
    }

    return 0;

}

sub shush {
    my $bag = shift;

    &do( $bag->{chl} => "is now gagged." );
    &talking( $bag->{chl}, 0 );
    Report( "$bag->{who} gagged in $bag->{chl}" );
    $gagged{$bag->{chl}} = 1;
}

sub free {
    my $bag = shift;

    $gagged{$bag->{chl}} = 0;
    &do( $bag->{chl} => "is FREE!" );
    &talking( $bag->{chl}, -1 );
    Report( "$bag->{who} removed gag in $bag->{chl}" );
}
