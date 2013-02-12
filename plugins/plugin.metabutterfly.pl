# BUCKET PLUGIN
# (Real Programmers Don't Write Perl)

use BucketBase qw/say/;

sub signals {
    return (qw/on_public/);
}

sub route {
    my ( $package, $sig, $data ) = @_;

    if ( $data->{msg} =~ /^real programmers/i ) {
        &say( $data->{chl} => "Real programmers cite http://xkcd.com/378/"
            . " and leave it at that." );
    }

    return 0;
}
