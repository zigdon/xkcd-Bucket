# BUCKET PLUGIN
# Dice plugin. Example usage:
# !d20, !2d12, !4d6+10, !3d12-5

use BucketBase qw/say config talking/;

sub signals {
	return (qw/on_public/);
}

sub settings {
	return (
		dice_max => [ i => 20 ],
		dice_max_sides => [ i => 1000 ],
	);
}

sub route {
	my ( $package, $sig, $data ) = @_;

	if ( $data->{msg} =~ /^!(\d+)?d(\d+)([+-](\d+))?$/i
		and &config("dice_max_sides")
		and &config("dice_max")
		and &talking( $data->{chl} ) == -1 )
		{
	
			my ($num, $sides, $plus) = ($data->{msg} =~ /^!(\d+)?d(\d+)([+-](\d+))?$/i);
			$num = 1 if not $num;
			$plus =~ tr/+ //d if $plus;
			
                        if ($sides > &config("dice_max_sides")) {
                                &say( $data->{chl} => "I don't have those kinds of dice! D:");
                                return 1;
                        }
                        if ($num > &config("dice_max")) {
                                &say( $data->{chl} => "You rolled too many dice.");
                                return 1;
                        }

			my @rolls;
			my $sum = $plus || 0;
			for (1 .. $num) {
				push @rolls, int rand( $sides ) + 1;
				$sum += $rolls[-1];
			}
	
			my $str = "You rolled a $sum";
			if (@rolls > 1 or $plus) {
				$plus = '' unless $plus;
				$plus =~ s/\-(\d)/ \- $1/;
				$plus =~ s/^(\d)/ \+ $1/;
				$str .= " (" . join( " + ", @rolls) . "$plus)";
			}
	
			&say( $data->{chl} => "$str" );
			return 1;
		}
	return 0;
}
