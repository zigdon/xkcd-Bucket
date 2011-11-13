# BUCKET PLUGIN

use BucketBase qw/say config talking/;

sub signals {
    return (qw/on_public/);
}

sub settings {
    return (
        squirrel_chance => [ p => 20 ],
        squirrel_shock  => [ i => 60 ],
    );
}

sub route {
    my ( $package, $sig, $data ) = @_;

    if (    $data->{msg} =~ /\bsquirrels?(?:\b|$)/i
        and &config("squirrel_shock")
        and rand(100) < &config("squirrel_chance")
        and &talking( $data->{chl} ) == -1 )
    {
        &say( $data->{chl} => "SQUIRREL!" );
        &say( $data->{chl} => "O_O" );
        POE::Kernel->delay_add(
            delayed_post => &config("squirrel_shock") / 2 => $data->{chl} =>
              "    O_O" );
        POE::Kernel->delay_add(
            delayed_post => &config("squirrel_shock") => $data->{chl} =>
              "  O_O" );

        # and shut up for the shock time
        &talking( $data->{chl}, time + &config("squirrel_shock") );

        # don't process any further
        return 1;
    }

    return 0;
}
