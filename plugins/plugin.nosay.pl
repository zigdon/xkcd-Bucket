# BUCKET PLUGIN

use BucketBase qw/cached_reply Log/;

sub signals {
    return (qw/on_public/)
}

sub route {
    my ( $package, $sig, $data ) = @_;

    if ( $sig eq 'on_public' ) {
        # first check if the line looks like teaching a factoid
        if ( $data->{msg} =~ /(.*?) (?:is ?|are ?)(<\w+>)\s*(.*)()/i
             or $data->{msg} =~ /(.*?)\s+(<\w+(?:'t)?>)\s*(.*)()/i
             or $data->{msg} =~ /(.*?)(<'s>)\s+(.*)()/i
             or $data->{msg} =~ /(.*?)\s+(is(?: also)?|are)\s+(.*)/i ) {
            return 0;  # if it looks like teaching, let processing continue
        # then if not, check if it would trigger the 'say' function
        } elsif ( $data->{msg} =~ /^say (.*)/i ) {
            if ( $data->{addressed} ) {
                &cached_reply( $data->{chl}, $data->{who}, "", "don't know" );
            }
            Log "$data->{who} tried to trigger 'say' in $data->{chl}; ignoring.";
            return 1;  # Halting core prevents default behavior, but plugins should (probably?) be allowed to continue
        }
    }

    return 0;
}
