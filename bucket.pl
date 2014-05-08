#!/usr/bin/perl -w
#  Copyright (C) 2011  Dan Boger - zigdon+bot@gmail.com
#
#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program; if not, write to the Free Software Foundation,
#  Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
#
# $Id: bucket.pl 685 2009-08-04 19:15:15Z dan $

use strict;
use POE;
use POE::Component::IRC;
use POE::Component::IRC::State;
use POE::Component::IRC::Plugin::NickServID;
use POE::Component::IRC::Plugin::Connector;
use POE::Component::SimpleDBI;
use Lingua::EN::Conjugate qw/past gerund/;
use Lingua::EN::Inflect qw/A PL_N/;
use Lingua::EN::Syllable qw//;    # don't import anything
use YAML qw/LoadFile DumpFile/;
use Data::Dumper;
use Fcntl qw/:seek/;
use HTML::Entities;
use URI::Escape;
use DBI;
$Data::Dumper::Indent = 1;

# try to load Math::BigFloat if possible
my $math = "";
eval { require Math::BigFloat; };
unless ($@) {
    $math = "Math::BigFloat";
    &Log("$math loaded");
}

sub DEBUG {
    return &config('debug');
}

# work around a bug: https://rt.cpan.org/Ticket/Display.html?id=50991
sub s_form { return Lingua::EN::Conjugate::s_form(@_); }

$SIG{CHLD} = 'IGNORE';

$|++;

### IRC portion
my $configfile = shift || "bucket.yml";
my $config     = LoadFile($configfile);
my $nick       = &config("nick") || "Bucket";
my $pass       = &config("password") || "somethingsecret";
$config->{nick} = $nick =
  &DEBUG ? ( &config("debug_nick") || "bucketgoat" ) : $nick;

my $channel =
  &DEBUG
  ? ( &config("debug_channel") || "#bucket" )
  : ( &config("control_channel") || "#billygoat" );
our ($irc) = POE::Component::IRC::State->spawn();
my %channels = ( $channel => 1 );
my $mainchannel = &config("main_channel") || "#xkcd";
my %_talking;
my %fcache;
my %stats;
my %undo;
my %last_activity;
my @inventory;
my @random_items;
my %replacables;
my %handles;
my %plugin_signals;
my @registered_commands;

my %config_keys = (
    autoload_plugins         => [ s => '' ],
    band_name                => [ p => 5 ],
    band_var                 => [ s => 'band' ],
    ex_to_sex                => [ p => 1 ],
    file_input               => [ f => "" ],
    idle_source              => [ s => 'factoid' ],
    increase_mute            => [ i => 60 ],
    inventory_preload        => [ i => 0 ],
    inventory_size           => [ i => 20 ],
    item_drop_rate           => [ i => 3 ],
    lookup_tla               => [ i => 10 ],
    max_sub_length           => [ i => 80 ],
    minimum_length           => [ i => 6 ],
    random_exclude_verbs     => [ s => '<reply>,<action>' ],
    random_item_cache_size   => [ i => 20 ],
    random_wait              => [ i => 3 ],
    repeated_queries         => [ i => 5 ],
    timeout                  => [ i => 60 ],
    the_fucking              => [ p => 100 ],
    tumblr_name              => [ p => 50 ],
    uses_reply               => [ i => 5 ],
    user_activity_timeout    => [ i => 360 ],
    value_cache_limit        => [ i => 1000 ],
    var_limit                => [ i => 3 ],
    your_mom_is              => [ p => 5 ],
);

$stats{startup_time} = time;
&open_log;

if ( &config("autoload_plugins") ) {
    foreach my $plugin ( split ' ', &config("autoload_plugins") ) {
        &load_plugin($plugin);
    }
}

my %gender_vars = (
    subjective => {
        male        => "he",
        female      => "she",
        androgynous => "they",
        inanimate   => "it",
        "full name" => "%N",
        aliases     => [qw/he she they it heshe shehe/]
    },
    objective => {
        male        => "him",
        female      => "her",
        androgynous => "them",
        inanimate   => "it",
        "full name" => "%N",
        aliases     => [qw/him her them himher herhim/]
    },
    reflexive => {
        male        => "himself",
        female      => "herself",
        androgynous => "themself",
        inanimate   => "itself",
        "full name" => "%N",
        aliases =>
          [qw/himself herself themself itself himselfherself herselfhimself/]
    },
    possessive => {
        male        => "his",
        female      => "hers",
        androgynous => "theirs",
        inanimate   => "its",
        "full name" => "%N's",
        aliases     => [qw/hers theirs hishers hershis/]
    },
    determiner => {
        male        => "his",
        female      => "her",
        androgynous => "their",
        inanimate   => "its",
        "full name" => "%N's",
        aliases     => [qw/their hisher herhis/]
    },
);

# make sure the file_input file is empty, if it is defined
# (so that we don't delete anything important by mistake)
if ( &config("file_input") and -f &config("file_input") ) {
    &Log(   "Ignoring the file_input directive since that file already exists "
          . "at startup" );
    delete $config->{file_input};
}

# set up gender aliases
foreach my $type ( keys %gender_vars ) {
    foreach my $alias ( @{$gender_vars{$type}{aliases}} ) {
        $gender_vars{$alias} = $gender_vars{$type};
        &Log("Setting gender alias: $alias => $type");
    }
}

$irc->plugin_add( 'NickServID',
    POE::Component::IRC::Plugin::NickServID->new( Password => $pass ) );

POE::Component::SimpleDBI->new('db') or die "Can't create DBI session";

POE::Session->create(
    inline_states => {
        _start           => \&irc_start,
        irc_001          => \&irc_on_connect,
        irc_kick         => \&irc_on_kick,
        irc_public       => \&irc_on_public,
        irc_ctcp_action  => \&irc_on_public,
        irc_msg          => \&irc_on_public,
        irc_notice       => \&irc_on_notice,
        irc_disconnected => \&irc_on_disconnect,
        irc_topic        => \&irc_on_topic,
        irc_join         => \&irc_on_join,
        irc_332          => \&irc_on_jointopic,
        irc_331          => \&irc_on_jointopic,
        irc_nick         => \&irc_on_nick,
        irc_chan_sync    => \&irc_on_chan_sync,
        db_success       => \&db_success,
        delayed_post     => \&delayed_post,
        heartbeat        => \&heartbeat,
    },
);

POE::Kernel->run;
print "POE::Kernel has left the building.\n";

sub Log {
    print scalar localtime, " - @_\n";
    if ( &config("logfile") ) {
        print LOG scalar localtime, " - @_\n";
    }
}

sub Report {
    my $delay = shift if $_[0] =~ /^\d+$/;
    my $logchannel = &DEBUG ? $channel : &config("logchannel");
    unshift @_, "REPORT:" if &DEBUG;

    if ( $logchannel and $irc ) {
        if ($delay) {
            Log "Delayed msg ($delay): @_";
            POE::Kernel->delay_add(
                delayed_post => 2 * $delay => $logchannel => "@_" );
        } else {
            &say( $logchannel, "@_" );
        }
    }
}

sub delayed_post {
    &say( $_[ARG0], $_[ARG1] );
}

sub irc_on_topic {
    my $chl   = $_[ARG1];
    my $topic = $_[ARG2];

    return if &signal_plugin( "on_topic", {chl => $chl, topic => $topic} );
}

sub irc_on_kick {
    my ($kicker) = split /!/, $_[ARG0];
    my $chl      = $_[ARG1];
    my $kickee   = $_[ARG2];
    my $desc     = $_[ARG3];

    Log "$kicker kicked $kickee from $chl";

    return
      if &signal_plugin(
        "on_kick",
        {
            kicker => $kicker,
            chl    => $chl,
            kickee => $kickee,
            desc   => $desc
        }
      );

    &lookup(
        msgs => [ "$kicker kicked $kickee", "$kicker kicked someone" ],
        chl  => $chl,
        who  => $kickee,
        op   => 1,
        type => 'irc_kick',
    );
}

sub irc_on_public {
    my ($who) = split /!/, $_[ARG0];
    my $type  = $_[STATE];
    my $chl   = $_[ARG1];
    $chl = $chl->[0] if ref $chl eq 'ARRAY';
    my $msg = $_[ARG2];
    $msg =~ s/\s\s+/ /g;
    my %bag;

    $bag{who}  = $who;
    $bag{msg}  = $msg;
    $bag{chl}  = $chl;
    $bag{type} = $type;

    if ( not $stats{tail_time} or time - $stats{tail_time} > 60 ) {
        &tail( $_[KERNEL] );
        $stats{tail_time} = time;
    }

    $last_activity{$chl} = time;

    if ( exists $config->{ignore}{lc $bag{who}} ) {
        Log("ignoring $bag{who} in $bag{chl}");
        return;
    }

    $bag{addressed} = 0;
    if ( $type eq 'irc_msg' or $bag{msg} =~ s/^$nick[:,]\s*|,\s+$nick\W+$//i ) {
        $bag{addressed} = 1;
        $bag{to}        = $nick;
    } else {
        $bag{msg} =~ s/^(\S+):\s*//;
        $bag{to} = $1;
    }

    $bag{op} = 0;
    if (   $irc->is_channel_member( $channel, $bag{who} )
        or $irc->is_channel_operator( $mainchannel, $bag{who} )
        or $irc->is_channel_owner( $mainchannel, $bag{who} )
        or $irc->is_channel_admin( $mainchannel, $bag{who} ) )
    {
        $bag{op} = 1;
    }

    # allow editing only in public channels (other than #bots), or by ops.
    $bag{editable} = 1 if ( $chl =~ /^#/ and $chl ne '#bots' ) or $bag{op};

    if ( $type eq 'irc_msg' ) {
        return if &signal_plugin( "on_msg", \%bag );
    } else {
        return if &signal_plugin( "on_public", \%bag );
    }

    my $editable  = $bag{editable};
    my $addressed = $bag{addressed};
    my $operator  = $bag{op};
    $msg = $bag{msg};

    # keep track of who's active in each channel
    if ( $chl =~ /^#/ ) {
        $stats{users}{$chl}{$bag{who}}{last_active} = time;
    }

    unless ( exists $stats{users}{genders}{lc $bag{who}} ) {
        &load_gender( $bag{who} );
    }

    # flood protection
    if ( not $operator and $addressed ) {
        $stats{last_talk}{$chl}{$bag{who}}{when} = time;
        if ( $stats{last_talk}{$chl}{$bag{who}}{count}++ > 20
            and time - $stats{last_talk}{$chl}{$bag{who}}{when} <
            &config("user_activity_timeout") )
        {
            if ( $stats{last_talk}{$chl}{$bag{who}}{count} == 21 ) {
                Report "Ignoring $bag{who} who is flooding in $chl.";
                &say( $chl =>
                      "$bag{who}, I'm a bit busy now, try again in 5 minutes?"
                );
            }
            return;
        }
    }

    $bag{msg} =~ s/^\s+|\s+$//g;

    unless ( &talking($chl) == -1 or ( $operator and $addressed ) ) {
        my $timeout = &talking($chl);
        if ( $addressed and &config("increase_mute") and $timeout > 0 ) {
            &talking( $chl, $timeout + &config("increase_mute") );
            Report "Shutting up longer in $chl - "
              . ( &talking($chl) - time )
              . " seconds remaining";
        }
        return;
    }

    if ( time - $stats{last_updated} > 600 ) {
        &get_stats( $_[KERNEL] );
        &clear_cache();
        &random_item_cache( $_[KERNEL], 1 );
    }

    if ( $type eq 'irc_msg' ) {
        $bag{chl} = $chl = $bag{who};
    }

    Log(
"$type($chl): $bag{who}(o=$operator, a=$addressed, e=$editable): $bag{msg}"
    );

    # check all registered commands
    foreach my $cmd (@registered_commands) {
        if (    $addressed >= $cmd->{addressed}
            and $operator >= $cmd->{operator}
            and $editable >= $cmd->{editable}
            and $bag{msg} =~ $cmd->{re} )
        {
            Log("Matched cmd '$cmd->{label}' from $cmd->{plugin}.");
            $cmd->{callback}->( \%bag );
            return;
        }
    }

    if (
            $addressed
        and $editable
        and $bag{msg} =~ m{ (.*?)    # $1 key to edit
                   \s+(?:=~|~=)\s+   # match operator
                   s(\W)             # start match ($2 delimiter)
                     (               # $3 - string to replace
                       [^\2]+        # anything but a delimiter
                     )               # end of $3
                   \2                # separator
                    (.*)             # $4 - text to replace with
                   \2
                   ([gi]*)           # $5 - i/g flags
                   \s* $             # trailing spaces
                 }x
      )
    {
        my ( $fact, $old, $new, $flag ) = ( $1, $3, $4, $5 );
        Report
          "$bag{who} is editing $fact in $chl: replacing '$old' with '$new'";
        Log "Editing $fact: replacing '$old' with '$new'";
        if ( $fact =~ /^#(\d+)$/ ) {
            &sql(
                'select * from bucket_facts where id = ?',
                [$1],
                {
                    %bag,
                    cmd     => "edit",
                    old     => $old,
                    'new'   => $new,
                    flag    => $flag,
                    db_type => 'MULTIPLE',
                }
            );
        } else {
            &sql(
                'select * from bucket_facts where fact = ? order by id',
                [$fact],
                {
                    %bag,
                    cmd     => "edit",
                    fact    => $fact,
                    old     => $old,
                    'new'   => $new,
                    flag    => $flag,
                    db_type => 'MULTIPLE',
                }
            );
        }
    } elsif (
        $bag{msg} =~ m{ (.*?)             # $1 key to look up
                   \s+(?:=~|~=)\s+   # match operator
                   (\W)              # start match (any delimiter, $2)
                     (               # $3 - string to search
                       [^\2]+        # anything but a delimiter
                     )               # end of $3
                   \2                # same delimiter that opened the match
            }x
      )
    {
        my ( $fact, $search ) = ( $1, $3 );
        $fact = &trim($fact);
        $bag{msg} = $fact;
        Log "Looking up a particular factoid - '$search' in '$fact'";
        &lookup( %bag, search => $search, );
    } elsif ( $addressed and $operator and $bag{msg} =~ /^list plugins\W*$/i ) {
        &say(
            $chl => "$bag{who}: Currently loaded plugins: "
              . &make_list(
                map { "$_($stats{loaded_plugins}{$_})" }
                sort keys %{$stats{loaded_plugins}}
              )
        );
    } elsif ( $addressed
        and $operator
        and $bag{msg} =~ /^load plugin (\w+)\W*$/i )
    {
        if ( &load_plugin( lc $1 ) ) {
            &say( $chl => "Okay, $bag{who}. Plugin $1 loaded." );
        } else {
            &say( $chl => "Sorry, $bag{who}. Plugin $1 failed to load." );
        }
    } elsif ( $addressed
        and $operator
        and $bag{msg} =~ /^unload plugin (\w+)\W*$/i )
    {
        &unload_plugin( lc $1 );
        &say( $chl => "Okay, $bag{who}. Plugin $1 unloaded." );
    } elsif ( $addressed and $bag{msg} =~ /^literal(?:\[([*\d]+)\])?\s+(.*)/i )
    {
        my ( $page, $fact ) = ( $1 || 1, $2 );
        $stats{literal}++;
        $fact = &trim($fact);
        $fact = &decommify($fact);
        Log "Literal[$page] $fact";
        &sql(
            'select id, verb, tidbit, mood, chance, protected from
              bucket_facts where fact = ? order by id',
            [$fact],
            {
                %bag,
                cmd       => "literal",
                page      => $page,
                fact      => $fact,
                addressed => $addressed,
                db_type   => 'MULTIPLE',
            }
        );
    } elsif ( $addressed
        and $operator
        and $bag{msg} =~ /^delete item #?(\d+)\W*$/i )
    {
        unless ( $stats{detailed_inventory}{$bag{who}} ) {
            &say( $chl => "$bag{who}: ask me for a detailed inventory first." );
            return;
        }

        my $num  = $1 - 1;
        my $item = $stats{detailed_inventory}{$bag{who}}[$num];
        unless ( defined $item ) {
            &say( $chl => "Sorry, $bag{who}, I can't find that!" );
            return;
        }
        &say( $chl => "Okay, $bag{who}, destroying '$item'" );
        @inventory = grep { $_ ne $item } @inventory;
        &sql( "delete from bucket_items where `what` = ?", [$item] );
        delete $stats{detailed_inventory}{$bag{who}}[$num];
    } elsif ( $addressed and $operator and $bag{msg} =~ /^delete ((#)?.+)/i ) {
        my $id   = $2;
        my $fact = $1;
        $stats{deleted}++;

        if ($id) {
            while ( $fact =~ s/#(\d+)\s*// ) {
                &sql(
                    'select fact, tidbit, verb, RE, protected, mood, chance
                      from bucket_facts where id = ?',
                    [$1],
                    {
                        %bag,
                        cmd     => "delete_id",
                        fact    => $1,
                        db_type => "SINGLE",
                    }
                );
            }
        } else {
            &sql(
                'select fact, tidbit, verb, RE, protected, mood, chance from
                  bucket_facts where fact = ?',
                [$fact],
                {
                    %bag,
                    cmd     => "delete",
                    fact    => $fact,
                    db_type => 'MULTIPLE',
                }
            );
        }
    } elsif (
        $addressed
        and $bag{msg} =~ /^(?:shut \s up | go \s away)
                      (?: \s for \s (\d+)([smh])?|
                          \s for \s a \s (bit|moment|while|min(?:ute)?))?[.!]?$/xi
      )
    {
        $stats{shutup}++;
        my ( $num, $unit, $word ) = ( $1, lc $2, lc $3 );
        if ($operator) {
            my $target = 0;
            unless ( $num or $word ) {
                $num = 60 * 60;    # by default, shut up for one hour
            }
            if ($num) {
                $target += $num if not $unit or $unit eq 's';
                $target += $num * 60           if $unit eq 'm';
                $target += $num * 60 * 60      if $unit eq 'h';
                $target += $num * 60 * 60 * 24 if $unit eq 'd';
                Report
                  "Shutting up in $chl at ${who}'s request for $target seconds";
                &say( $chl => "Okay $bag{who}.  I'll be back later" );
                &talking( $chl, time + $target );
            } elsif ($word) {
                $target += 60 if $word eq 'min' or $word eq 'minute';
                $target += 30 + int( rand(60) )           if $word eq 'moment';
                $target += 4 * 60 + int( rand( 4 * 60 ) ) if $word eq 'bit';
                $target += 30 * 60 + int( rand( 30 * 60 ) ) if $word eq 'while';
                Report
                  "Shutting up in $chl at ${who}'s request for $target seconds";
                &say( $chl => "Okay $bag{who}.  I'll be back later" );
                &talking( $chl, time + $target );
            }
        } else {
            &say( $chl => "Okay, $bag{who} - be back in a bit!" );
            &talking( $chl, time + &config("timeout") );
        }
    } elsif ( $addressed
        and $operator
        and $bag{msg} =~ /^unshut up\W*$|^come back\W*$/i )
    {
        &say( $chl => "\\o/" );
        &talking( $chl, -1 );
    } elsif ( $addressed
        and $operator
        and $bag{msg} =~ /^(join|part) (#[-\w]+)(?: (.*))?/i )
    {
        my ( $cmd, $dst, $msg ) = ( $1, $2, $3 );
        unless ($dst) {
            &say( $chl => "$bag{who}: $cmd what channel?" );
            return;
        }
        $irc->yield( $cmd => $msg ? ( $dst, $msg ) : $dst );
        &say( $chl => "$bag{who}: ${cmd}ing $dst" );
        Report "${cmd}ing $dst at ${who}'s request";
    } elsif ( $addressed and $operator and lc $bag{msg} eq 'list ignored' ) {
        &say(
            $chl => "Currently ignored: ",
            join ", ", sort keys %{$config->{ignore}}
        );
    } elsif ( $addressed
        and $operator
        and $bag{msg} =~ /^([\w']+) has (\d+) syllables?\W*$/i )
    {
        $config->{sylcheat}{lc $1} = $2;
        &save;
        &say( $chl => "Okay, $bag{who}.  Cheat sheet updated." );
    } elsif ( $addressed and $operator and $bag{msg} =~ /^(un)?ignore (\S+)/i )
    {
        Report "$bag{who} is $1ignoring $2";
        if ($1) {
            delete $config->{ignore}{lc $2};
        } else {
            $config->{ignore}{lc $2} = 1;
        }
        &save;
        &say( $chl => "Okay, $bag{who}.  Ignore list updated." );
    } elsif ( $addressed and $operator and $bag{msg} =~ /^(un)?exclude (\S+)/i )
    {
        Report "$bag{who} is $1excluding $2";
        if ($1) {
            delete $config->{exclude}{lc $2};
        } else {
            $config->{exclude}{lc $2} = 1;
        }
        &save;
        &say( $chl => "Okay, $bag{who}.  Exclude list updated." );
    } elsif ( $addressed and $operator and $bag{msg} =~ /^(un)?protect (.+)/i )
    {
        my ( $protect, $fact ) = ( ( $1 ? 0 : 1 ), $2 );
        Report "$bag{who} is $1protecting $fact";
        Log "$1protecting $fact";

        if ( $fact =~ s/^\$// ) {    # it's a variable!
            unless ( exists $replacables{lc $fact} ) {
                &say( $chl =>
                      "Sorry, $bag{who}, \$$fact isn't a valid variable." );
                return;
            }

            $replacables{lc $fact}{perms} = $protect ? "read-only" : "editable";
        } else {
            &sql( 'update bucket_facts set protected=? where fact=?',
                [ $protect, $fact ] );
        }
        &say( $chl => "Okay, $bag{who}, updated the protection bit." );
    } elsif ( $addressed and $bag{msg} =~ /^undo last(?: (#\S+))?/ ) {
        Log "$bag{who} called undo:";
        my $uchannel = $1 || $chl;
        my $undo = $undo{$uchannel};
        unless ( $operator or $undo->[1] eq $bag{who} ) {
            &say( $chl => "Sorry, $bag{who}, you can't undo that." );
            return;
        }
        Log Dumper $undo;
        if ( $undo->[0] eq 'delete' ) {
            &sql(
                'delete from bucket_facts where id=? limit 1',
                [ $undo->[2] ],
            );
            Report "$bag{who} called undo: deleted $undo->[3].";
            &say( $chl => "Okay, $bag{who}, deleted $undo->[3]." );
            delete $undo{$uchannel};
        } elsif ( $undo->[0] eq 'insert' ) {
            if ( $undo->[2] and ref $undo->[2] eq 'ARRAY' ) {
                foreach my $entry ( @{$undo->[2]} ) {
                    my %old = %$entry;
                    $old{RE}        = 0 unless $old{RE};
                    $old{protected} = 0 unless $old{protected};
                    &sql(
                        'insert bucket_facts
                          (fact, verb, tidbit, protected, RE, mood, chance)
                          values(?, ?, ?, ?, ?, ?, ?)',
                        [ @old{qw/fact verb tidbit protected RE mood chance/} ],
                    );
                }
                Report "$bag{who} called undo: undeleted $undo->[3].";
                &say( $chl => "Okay, $bag{who}, undeleted $undo->[3]." );
            } elsif ( $undo->[2] and ref $undo->[2] eq 'HASH' ) {
                my %old = %{$undo->[2]};
                $old{RE}        = 0 unless $old{RE};
                $old{protected} = 0 unless $old{protected};
                &sql(
                    'insert bucket_facts
                      (id, fact, verb, tidbit, protected, RE, mood, chance)
                      values(?, ?, ?, ?, ?, ?, ?, ?)',
                    [ @old{qw/id fact verb tidbit protected RE mood chance/} ],
                );
                Report "$bag{who} called undo:",
                  "unforgot $old{fact} $old{verb} $old{tidbit}.";
                &say( $chl =>
"Okay, $bag{who}, unforgot $old{fact} $old{verb} $old{tidbit}."
                );
            } else {
                &say( $chl =>
                        "Sorry, $bag{who}, that's an invalid undo structure."
                      . "  Tell Zigdon, please." );
            }

        } elsif ( $undo->[0] eq 'edit' ) {
            if ( $undo->[2] and ref $undo->[2] eq 'ARRAY' ) {
                foreach my $entry ( @{$undo->[2]} ) {
                    if ( $entry->[0] eq 'update' ) {
                        &sql(
                            'update bucket_facts set verb=?, tidbit=?
                              where id=? limit 1',
                            [ $entry->[2], $entry->[3], $entry->[1] ],
                        );
                    } elsif ( $entry->[0] eq 'insert' ) {
                        my %old = %{$entry->[1]};
                        $old{RE}        = 0 unless $old{RE};
                        $old{protected} = 0 unless $old{protected};
                        &sql(
                            'insert bucket_facts
                              (fact, verb, tidbit, protected, RE, mood, chance)
                              values(?, ?, ?, ?, ?, ?, ?)',
                            [
                                @old{
                                    qw/fact verb tidbit protected RE mood chance/
                                }
                            ],
                        );
                    }
                }
                Report "$bag{who} called undo: undone $undo->[3].";
                &say( $chl => "Okay, $bag{who}, undone $undo->[3]." );
            } else {
                &say( $chl =>
                        "Sorry, $bag{who}, that's an invalid undo structure."
                      . "  Tell Zigdon, please." );
            }
            delete $undo{$uchannel};
        } else {
            &say( $chl => "Sorry, $bag{who}, can't undo $undo->[0] yet" );
        }
    } elsif ( $addressed and $operator and $bag{msg} =~ /^merge (.*) => (.*)/ )
    {
        my ( $src, $dst ) = ( $1, $2 );
        $stats{merge}++;

        &sql(
            'select id, verb, tidbit from bucket_facts where fact = ? limit 1',
            [$src],
            {
                %bag,
                cmd     => "merge",
                src     => $src,
                dst     => $dst,
                db_type => "SINGLE",
            }
        );
    } elsif ( $addressed and $operator and $bag{msg} =~ /^alias (.*) => (.*)/ )
    {
        my ( $src, $dst ) = ( $1, $2 );
        $stats{alias}++;

        &sql(
            'select id, verb, tidbit from bucket_facts where fact = ? limit 1',
            [$src],
            {
                %bag,
                cmd     => "alias1",
                src     => $src,
                dst     => $dst,
                db_type => "SINGLE",
            }
        );
    } elsif ( $operator and $addressed and $bag{msg} =~ /^lookup #?(\d+)\W*$/ )
    {
        &sql(
            'select id, fact, verb, tidbit from bucket_facts where id = ? ',
            [$1],
            {
                %bag,
                msg       => undef,
                cmd       => "fact",
                addressed => 0,
                editable  => 0,
                op        => 0,
                db_type   => "SINGLE",
            }
        );
    } elsif ( $operator
        and $addressed
        and $bag{msg} =~ /^forget (?:that|#(\d+))\W*$/ )
    {
        my $id = $1 || $stats{last_fact}{$chl};
        unless ($id) {
            &say( $chl => "Sorry, $bag{who}, forget what?" );
            return;
        }

        &sql( 'select * from bucket_facts where id = ?',
            [$id], {%bag, cmd => "forget", id => $id, db_type => "SINGLE",} );
    } elsif ( $addressed and $bag{msg} =~ /^what was that\??$/i ) {
        my $id = $stats{last_fact}{$chl};
        unless ($id) {
            &say( $chl => "Sorry, $bag{who}, I have no idea." );
            return;
        }

        if ( $id =~ /^(\d+)$/ ) {
            &sql( 'select * from bucket_facts where id = ?',
                [$id],
                {%bag, cmd => "report", id => $id, db_type => "SINGLE",} );
        } else {
            &say( $chl => "$bag{who}: that was $id" );
        }
    } elsif ( $addressed and $bag{msg} eq 'something random' ) {
        &lookup(%bag);
    } elsif ( $addressed and $bag{msg} eq 'stats' ) {
        unless ( $stats{stats_cached} ) {
            &say( $chl => "$bag{who}: Hold on, I'm still counting" );
            return;
        }

        # get the last modified time for any bit of the code
        my $mtime = ( stat($0) )[9];
        my $dir   = &config("plugin_dir");
        if ( $dir and opendir( PLUGINS, $dir ) ) {
            foreach my $file ( readdir(PLUGINS) ) {
                next unless $file =~ /^plugin\.\w+\.pl$/;
                if ( $mtime < ( stat("$dir/$file") )[9] ) {
                    $mtime = ( stat(_) )[9];
                }
            }
            closedir PLUGINS;
        }

        my ( $mod,   $modu )  = &round_time( time - $mtime );
        my ( $awake, $units ) = &round_time( time - $stats{startup_time} );

        my $reply;
        $reply = sprintf "I've been awake since %s (about %d %s), ",
          scalar localtime( $stats{startup_time} ),
          $awake, $units;

        if ( $awake != $mod or $units ne $modu ) {
            if ( ( stat($0) )[9] < $stats{startup_time} ) {
                $reply .= sprintf "and was last changed about %d %s ago. ",
                  $mod, $modu;
            } else {
                $reply .=
                  sprintf "and a newer version has been available for %d %s. ",
                  $mod, $modu;
            }
        } else {
            $reply .= "and that was when I was last changed. ";
        }

        if ( $stats{learn} + $stats{edited} + $stats{deleted} ) {
            $reply .= "Since waking up, I've ";
            my @fact_stats;
            push @fact_stats,
              sprintf "learned %d new factoid%s",
              $stats{learn}, &s( $stats{learn} )
              if ( $stats{learn} );
            push @fact_stats,
              sprintf "updated %d factoid%s", $stats{edited},
              &s( $stats{edited} )
              if ( $stats{edited} );
            push @fact_stats,
              sprintf "forgot %d factoid%s",
              $stats{deleted}, &s( $stats{deleted} )
              if ( $stats{deleted} );
            push @fact_stats, sprintf "found %d haiku", $stats{haiku}
              if ( $stats{haiku} );

            # strip out the string 'factoids' from all but the first entry
            if ( @fact_stats > 1 ) {
                s/ factoids?// foreach @fact_stats[ 1 .. $#fact_stats ];
            }

            if (@fact_stats) {
                $reply .= &make_list(@fact_stats) . ". ";
            } else {
                $reply .= "haven't had a chance to do much!";
            }
        }
        $reply .= sprintf "I know now a total of %s thing%s "
          . "about %s subject%s. ",
          &commify( $stats{rows} ),     &s( $stats{rows} ),
          &commify( $stats{triggers} ), &s( $stats{triggers} );
        $reply .=
          sprintf "I know of %s object%s" . " and am carrying %d of them. ",
          &commify( $stats{items} ), &s( $stats{items} ), scalar @inventory;
        if ( &talking($chl) == 0 ) {
            $reply .= "I'm being quiet right now. ";
        } elsif ( &talking($chl) > 0 ) {
            $reply .=
              sprintf "I'm being quiet right now, "
              . "but I'll be back in about %s %s. ",
              &round_time( &talking($chl) - time );
        }
        &say( $chl => $reply );
    } elsif ( $operator and $addressed and $bag{msg} =~ /^stat (\w+)\??/ ) {
        my $key = $1;
        if ( $key eq 'keys' ) {
            &say_long( $chl => "$bag{who}: valid keys are: "
                  . &make_list( sort keys %stats )
                  . "." );
        } elsif ( exists $stats{$key} ) {
            if ( ref $stats{$key} ) {
                my $dump = Dumper( $stats{$key} );
                $dump =~ s/[\s\n]+/ /g;
                &say( $chl => "$bag{who}: $key: $dump." );
                Log $dump;
            } else {
                &say( $chl => "$bag{who}: $key: $stats{$key}." );
            }
        } else {
            &say( $chl =>
                  "Sorry, $bag{who}, I don't have statistics for '$key'." );
        }
    } elsif ( $operator and $addressed and $bag{msg} eq 'restart' ) {
        Report "Restarting at ${who}'s request";
        Log "Restarting at ${who}'s request";
        &say( $chl => "Okay, $bag{who}, I'll be right back." );
        $irc->yield( quit => "OHSHI--" );
    } elsif ( $operator
        and $addressed
        and $bag{msg} =~ /^set(?: (\w+) (.*)|$)/ )
    {
        my ( $key, $val ) = ( $1, $2 );

        unless ( $key and exists $config_keys{$key} ) {
            &say_long( $chl => "$bag{who}: Valid keys are: "
                  . &make_list( sort keys %config_keys ) );
            return;
        }

        if ( $config_keys{$key}[0] eq 'p' and $val =~ /^(\d+)%?$/ ) {
            $config->{$key} = $1;
        } elsif ( $config_keys{$key}[0] eq 'i' and $val =~ /^(\d+)$/ ) {
            $config->{$key} = $1;
        } elsif ( $config_keys{$key}[0] eq 's' ) {
            $val =~ s/^\s+|\s+$//g;
            $config->{$key} = $val;
        } elsif ( $config_keys{$key}[0] eq 'b' and $val =~ /^(true|false)$/ ) {
            $config->{$key} = $val eq 'true';
        } elsif ( $config_keys{$key}[0] eq 'f' and length $val ) {
            if ( -f $val ) {
                &say( $chl => "Sorry, $bag{who}, $val already exists." );
                return;
            } else {
                $config->{$key} = $val;
            }
        } else {
            &say(
                $chl => "Sorry, $bag{who}, that's an invalid value for $key." );
            return;
        }

        &say( $chl => "Okay, $bag{who}." );
        Report "$bag{who} set '$key' to '$val'";

        &save;
        return;
    } elsif ( $operator and $addressed and $bag{msg} =~ /^get (\w+)\W*$/ ) {
        my ($key) = ($1);
        unless ( exists $config_keys{$key} ) {
            &say_long( $chl => "$bag{who}: Valid keys are: "
                  . &make_list( sort keys %config_keys ) );
            return;
        }

        &say( $chl => "$key is", &config("$key") . "." );
    } elsif ( $addressed and $bag{msg} eq 'list vars' ) {
        unless ( keys %replacables ) {
            &say( $chl => "Sorry, $bag{who}, there are no defined variables!" );
            return;
        }
        &say(
            $chl => "Known variables:",
            &make_list(
                map {
                        $replacables{$_}->{type} eq 'noun' ? "$_(n)"
                      : $replacables{$_}->{type} eq 'verb' ? "$_(v)"
                      : $_
                  }
                  sort keys %replacables
              )
              . "."
        );
    } elsif ( $addressed and $bag{msg} =~ /^list var (\w+)$/ ) {
        my $var = $1;
        unless ( exists $replacables{$var} ) {
            &say( $chl => "Sorry, $bag{who}, I don't know a variable '$var'." );
            return;
        }

        unless (
            $replacables{$var}{cache}
            or ( ref $replacables{$var}{vals} eq 'ARRAY'
                and @{$replacables{$var}{vals}} )
          )
        {
            &say( $chl => "$bag{who}: \$$var has no values defined!" );
            return;
        }

        if ( exists $replacables{$var}{cache}
            or ref $replacables{$var}{vals} eq 'ARRAY'
            and @{$replacables{$var}{vals}} > 30 )
        {
            if ( &config("www_root") ) {
                &sql(
                    'select value
                      from bucket_vars vars
                           left join bucket_values vals
                           on vars.id = vals.var_id
                      where name = ?
                      order by value',
                    [$var],
                    {
                        %bag,
                        cmd     => "dump_var",
                        name    => $var,
                        db_type => 'MULTIPLE',
                    }
                );
            } else {
                &say( $chl =>
                      "Sorry, $bag{who}, I can't print $replacables{$var}{vals}"
                      . "values to the channel." );
            }
            return;
        }

        my @vals = @{$replacables{$var}{vals}};
        &say( $chl => "$var:", &make_list( sort @vals ) );
    } elsif ( $addressed and $bag{msg} =~ /^remove value (\w+) (.+)$/ ) {
        my ( $var, $value ) = ( lc $1, lc $2 );
        unless ( exists $replacables{$var} ) {
            &say( $chl =>
                  "Sorry, $bag{who}, I don't know of a variable '$var'." );
            return;
        }

        if ( $replacables{$var}{perms} ne "editable" and not $operator ) {
            &say( $chl =>
                  "Sorry, $bag{who}, you don't have permissions to edit '$var'."
            );
            return;
        }

        my $key = "vals";
        if ( exists $replacables{$var}{cache} ) {
            $key = "cache";

            &sql(
                "delete from bucket_values where var_id=? and value=? limit 1",
                [ $replacables{$var}{id}, $value ]
            );
            &say( $chl => "Okay, $bag{who}." );
            Report "$bag{who} removed a value from \$$var in $chl: $value";
        }

        foreach my $i ( 0 .. @{$replacables{$var}{$key}} - 1 ) {
            next unless lc $replacables{$var}{$key}[$i] eq $value;

            Log "found!";
            splice( @{$replacables{$var}{vals}}, $i, 1, () );

            return if ( $key eq 'cache' );

            &say( $chl => "Okay, $bag{who}." );
            Report "$bag{who} removed a value from \$$var in $chl: $value";
            &sql(
                "delete from bucket_values where var_id=? and value=? limit 1",
                [ $replacables{$var}{id}, $value ]
            );

            return;
        }

        return if $key eq 'cache';

        &say( $chl => "$bag{who}, '$value' isn't a valid value for \$$var!" );
    } elsif ( $addressed and $bag{msg} =~ /^add value (\w+) (.+)$/ ) {
        my ( $var, $value ) = ( lc $1, $2 );
        unless ( exists $replacables{$var} ) {
            &say( $chl =>
                  "Sorry, $bag{who}, I don't know of a variable '$var'." );
            return;
        }

        if ( $replacables{$var}{perms} ne "editable" and not $operator ) {
            &say( $chl =>
                  "Sorry, $bag{who}, you don't have permissions to edit '$var'."
            );
            return;
        }

        if ( $value =~ /\$/ ) {
            &say( $chl => "Sorry, $bag{who}, no nested values please." );
            return;
        }

        foreach my $v ( @{$replacables{$var}{vals}} ) {
            next unless lc $v eq lc $value;

            &say( $chl => "$bag{who}, I had it that way!" );
            return;
        }

        if ( exists $replacables{$var}{vals} ) {
            push @{$replacables{$var}{vals}}, $value;
        } else {
            push @{$replacables{$var}{cache}}, $value;
        }
        &say( $chl => "Okay, $bag{who}." );
        Report "$bag{who} added a value to \$$var in $chl: $value";

        &sql( "insert into bucket_values (var_id, value) values (?, ?)",
            [ $replacables{$var}{id}, $value ] );
    } elsif ( $operator
        and $addressed
        and $bag{msg} =~ /^create var (\w+)\W*$/ )
    {
        my $var = $1;
        if ( exists $replacables{$var} ) {
            &say( $chl =>
                  "Sorry, $bag{who}, there already exists a variable '$var'." );
            return;
        }

        $replacables{$var} = {vals => [], perms => "read-only", type => "var"};
        Log "$bag{who} created a new variable '$var' in $chl";
        Report "$bag{who} created a new variable '$var' in $chl";
        $undo{$chl} = [ 'newvar', $bag{who}, $var, "new variable '$var'." ];
        &say( $chl => "Okay, $bag{who}." );

        &sql( 'insert into bucket_vars (name, perms) values (?, "read-only")',
            [$var], {cmd => "create_var", var => $var} );
    } elsif ( $operator
        and $addressed
        and $bag{msg} =~ /^remove var (\w+)\s*(!+)?$/ )
    {
        my $var = $1;
        unless ( exists $replacables{$var} ) {
            &say( $chl => "Sorry, $bag{who}, there isn't a variable '$var'!" );
            return;
        }

        if ( exists $replacables{$var}{cache} and not $2 ) {
            &say( $chl =>
"$bag{who}, this action cannot be undone.  If you want to proceed "
                  . "append a '!'" );

            return;
        }

        if ( exists $replacables{$var}{vals} ) {
            $undo{$chl} = [
                'delvar', $bag{who}, $var, $replacables{$var},
                "deletion of variable '$var'."
            ];
            &say(
                $chl => "Okay, $bag{who}, removed variable \$$var with",
                scalar @{$replacables{$var}{vals}}, "values."
            );
        } else {
            &say( $chl => "Okay, $bag{who}, removed variable \$$var." );
        }

        &sql( "delete from bucket_values where var_id = ?",
            [ $replacables{$var}{id} ] );
        &sql( "delete from bucket_vars where id = ?",
            [ $replacables{$var}{id} ] );
        delete $replacables{$var};
    } elsif ( $operator
        and $addressed
        and $bag{msg} =~ /^var (\w+) type (var|verb|noun)\W*$/ )
    {
        my ( $var, $type ) = ( $1, $2 );
        unless ( exists $replacables{$var} ) {
            &say( $chl => "Sorry, $bag{who}, there isn't a variable '$var'!" );
            return;
        }

        Log "$bag{who} set var $var type to $type";
        &say( $chl => "Okay, $bag{who}" );
        $replacables{$var}{type} = $type;
        &sql( "update bucket_vars set type=? where id = ?",
            [ $type, $replacables{$var}{id} ] );
    } elsif ( $operator
        and $addressed
        and $bag{msg} =~ /^(?:detailed inventory|list item details)[?.!]?$/i )
    {
        unless (@inventory) {
            &say( $chl => "Sorry, $bag{who}, I'm not carrying anything!" );
            return;
        }
        $stats{detailed_inventory}{$bag{who}} = [];
        my $line;
        push @{$stats{detailed_inventory}{$bag{who}}}, sort @inventory;
        my $c = 1;
        &say_long(
            $chl => "$bag{who}: " . join "; ",
            map { $c++ . ": $_" } @{$stats{detailed_inventory}{$bag{who}}}
        );
    } elsif ( $addressed and $bag{msg} =~ /^(?:inventory|list items)[?.!]?$/i )
    {
        &cached_reply( $chl, $bag{who}, "", "list items" );
    } elsif (
        $addressed
        and $bag{msg} =~ /^(?:(I|[-\w]+) \s (?:am|is)|
                         I'm(?: an?)?) \s
                       (
                         male          |
                         female        |
                         androgynous   |
                         inanimate     |
                         full \s name  |
                         random gender
                       )\.?$/ix
        or $bag{msg} =~ / ^(I|[-\w]+) \s (am|is) \s an? \s
                       ( he | she | him | her | it )\.?$
                     /ix
      )
    {
        my ( $target, $gender, $pronoun ) = ( $1, $2, $3 );
        if (    uc $target ne "I"
            and lc $target ne lc $bag{who}
            and not $operator )
        {
            &say( $chl =>
                  "$bag{who}, you should let $target set their own gender." );
            return;
        }

        $target = $bag{who} if uc $target eq 'I';

        if ($pronoun) {
            $gender = undef;
            $gender = "male" if $pronoun eq 'him' or $pronoun eq 'he';
            $gender = "female" if $pronoun eq 'her' or $pronoun eq 'she';
            $gender = "inanimate" if $pronoun eq 'it';

            unless ($gender) {
                &say( $chl => "Sorry, $bag{who}, I didn't understand that." );
                return;
            }
        }

        Log "$bag{who} set ${target}'s gender to $gender";
        $stats{users}{genders}{lc $target} = lc $gender;
        &sql( "replace genders (nick, gender, stamp) values (?, ?, ?)",
            [ $target, $gender, undef ] );
        &say( $chl => "Okay, $bag{who}" );
    } elsif ( $addressed
        and $bag{msg} =~ /^what is my gender\??$|^what gender am I\??/i )
    {
        if ( exists $stats{users}{genders}{lc $bag{who}} ) {
            &say(
                $chl => "$bag{who}: Grammatically, I refer to you as",
                $stats{users}{genders}{lc $bag{who}} . ".  See",
                "http://wiki.xkcd.com/irc/Bucket#Docs for information on",
                "setting this."
            );

        } else {
            &load_gender( $bag{who} );
            &say( $chl => "$bag{who}: I don't know how to refer to you!" );
        }
    } elsif ( $addressed and $bag{msg} =~ /^what gender is ([-\w]+)\??$/i ) {
        if ( exists $stats{users}{genders}{lc $1} ) {
            &say( $chl => "$bag{who}: $1 is $stats{users}{genders}{lc $1}." );
        } else {
            &load_gender($1);
            &say( $chl => "$bag{who}: I don't know how to refer to $1!" );
        }
    } elsif ( $bag{msg} =~ /^uses(?: \S+){1,5}$/i
        and &config("uses_reply")
        and rand(100) < &config("uses_reply") )
    {
        &cached_reply( $chl, $bag{who}, undef, "uses reply" );
    } elsif ( &config("lookup_tla") > 0
        and rand(100) < &config("lookup_tla")
        and $bag{msg} =~ /^([A-Z])([A-Z])([A-Z])\??$/ )
    {
        my $pattern = "$1% $2% $3%";
        &sql(
            'select value
              from bucket_values
                   left join bucket_vars
                   on var_id = bucket_vars.id
              where name = ?  and value like ?
              order by rand()
              limit 1',
            [ &config("band_var"), $pattern ],
            {%bag, cmd => "tla", tla => $bag{msg}, db_type => 'SINGLE',}
        );
    } else {
        my $orig = $bag{msg};
        $bag{msg} = &trim( $bag{msg} );
        if (   $addressed
            or length $bag{msg} >= &config("minimum_length")
            or $bag{msg} eq '...' )
        {
            if ( $addressed and length $bag{msg} == 0 ) {
                $bag{msg} = $nick;
            }

            if (    not $operator
                and $type eq 'irc_public'
                and &config("repeated_queries") > 0 )
            {
                unless ( $stats{users}{$chl}{$bag{who}}{last_lookup} ) {
                    $stats{users}{$chl}{$bag{who}}{last_lookup} =
                      [ $bag{msg}, 0 ];
                }

                if ( $stats{users}{$chl}{$bag{who}}{last_lookup}[0] eq
                    $bag{msg} )
                {
                    if ( ++$stats{users}{$chl}{$bag{who}}{last_lookup}[1] ==
                        &config("repeated_queries") )
                    {
                        Report "Volunteering a dump of '$bag{msg}' for" .
                               " $bag{who} in $chl (if it exists)";
                        &sql(
                            'select id, verb, tidbit, mood, chance, protected
                              from bucket_facts where fact = ? order by id',
                            [ $bag{msg} ],
                            {
                                %bag,
                                cmd     => "literal",
                                page    => "*",
                                fact    => $bag{msg},
                                db_type => 'MULTIPLE',
                            }
                        );
                        return;
                    } elsif ( $stats{users}{$chl}{$bag{who}}{last_lookup}[1] >
                        &config("repeated_queries") )
                    {
                        Log "Ignoring $bag{who} who is asking '$bag{msg}'" .
                            " in $chl";
                        return;
                    }
                } else {
                    $stats{users}{$chl}{$bag{who}}{last_lookup} =
                      [ $bag{msg}, 1 ];
                }
            }

            &lookup( %bag, orig => $orig );
        }
    }
}

sub db_success {
    my $res = $_[ARG0];

    foreach ( keys %$res ) {
        if (    $_ eq 'RESULT'
            and ref $res->{RESULT} eq 'ARRAY'
            and @{$res->{RESULT}} > 50 )
        {
            print "RESULT: ", scalar @{$res->{RESULT}}, "\n";
        } else {
            print "$_:\n", Dumper $res->{$_} if /BAGGAGE|PLACEHOLDERS|RESULT/;
        }
    }
    my %bag = ref $res->{BAGGAGE} ? %{$res->{BAGGAGE}} : ();
    if ( $res->{ERROR} ) {

        if ( $res->{ERROR} eq 'Lost connection to the database server.' ) {
            Report "DB Error: $res->{ERROR}  Restarting.";
            Log "DB Error: $res->{ERROR}";
            &say( $channel => "Database lost.  Self-destruct initiated." );
            $irc->yield( quit => "Eep, the house is on fire!" );
            return;
        }
        Report "DB Error: $res->{QUERY} -> $res->{ERROR}";
        Log "DB Error: $res->{QUERY} -> $res->{ERROR}";
        if ( $bag{chl} and $bag{addressed} ) {
            &say( $bag{chl} =>
                  "Something is terribly wrong. I'll be back later." );
            &say( $channel =>
"Something's wrong with the database. Shutting up in $bag{chl} for an hour."
            );
            &talking( $bag{chl}, time + 60 * 60 );
        }
        return;
    }

    return unless $bag{cmd};

    return if &signal_plugin( "db_success", {bag => \%bag, res => $res} );

    if ( $bag{cmd} eq 'fact' ) {
        my %line = ref $res->{RESULT} ? %{$res->{RESULT}} : ();
        if ( defined $line{tidbit} ) {

            if ( $line{verb} eq '<alias>' ) {
                if ( $bag{aliases}{$line{tidbit}} ) {
                    Report "Alias loop detected when '$line{fact}'"
                      . " is aliased to '$line{tidbit}'";
                    Log "Alias loop detected when '$line{fact}'"
                      . " is aliased to '$line{tidbit}'";
                    &error( $bag{chl}, $bag{who} );
                    return;
                }
                $bag{aliases}{$line{tidbit}} = 1;
                $bag{alias_chain} .= "'$line{fact}' => ";

                Log "Following alias '$line{fact}' -> '$line{tidbit}'";
                &lookup( %bag, msg => $line{tidbit} );
                return;
            }

            $bag{msg}  = $line{fact} unless defined $bag{msg};
            $bag{orig} = $line{fact} unless defined $bag{orig};

            $stats{last_vars}{$bag{chl}}        = {};
            $stats{last_fact}{$bag{chl}}        = $line{id};
            $stats{last_alias_chain}{$bag{chl}} = $bag{alias_chain};
            $stats{lookup}++;

         # if we're just idle chatting, replace any $who reference with $someone
            if ( $bag{idle} ) {
                $bag{who} = &someone( $bag{chl} );
            }

            $line{tidbit} =
              &expand( $bag{who}, $bag{chl}, $line{tidbit}, $bag{editable},
                $bag{to} );
            return unless $line{tidbit};

            if ( $line{verb} eq '<reply>' ) {
                &say( $bag{chl} => $line{tidbit} );
            } elsif ( $line{verb} eq '\'s' ) {
                &say( $bag{chl} => "$bag{orig}'s $line{tidbit}" );
            } elsif ( $line{verb} eq '<action>' ) {
                &do( $bag{chl} => $line{tidbit} );
            } else {
                if ( lc $bag{msg} eq 'bucket' and lc $line{verb} eq 'is' ) {
                    $bag{orig}   = 'I';
                    $line{verb} = 'am';
                }
                &say( $bag{chl} => "$bag{msg} $line{verb} $line{tidbit}" );
            }
            return;
        } elsif ( $bag{msg} =~ s/^what is |^what's |^the //i ) {
            &lookup(%bag);
            return;
        }

        if (
                $bag{editable}
            and $bag{addressed}
            and (  $bag{orig} =~ /(.*?) (?:is ?|are ?)(<\w+>)\s*(.*)()/i
                or $bag{orig} =~ /(.*?)\s+(<\w+(?:'t)?>)\s*(.*)()/i
                or $bag{orig} =~ /(.*?)(<'s>)\s+(.*)()/i
                or $bag{orig} =~ /(.*?)\s+(is(?: also)?|are)\s+(.*)/i )
          )
        {
            my ( $fact, $verb, $tidbit, $forced ) = ( $1, $2, $3, defined $4 );

            if ( not $bag{addressed} and $fact =~ /^[^a-zA-Z]*<.?\S+>/ ) {
                Log "Not learning from what seems to be an IRC quote: $fact";

                # don't learn from IRC quotes
                return;
            }

            if ( $tidbit =~ /=~/ and not $forced ) {
                Log "Not learning what looks like a botched =~ query";
                &say( $bag{chl} => "$bag{who}: Fix your =~ command." );
                return;
            }

            if ( $fact eq 'you' and $verb eq 'are' ) {
                $fact = $nick;
                $verb = "is";
            } elsif ( $fact eq 'I' and $verb eq 'am' ) {
                $fact = $bag{who};
                $verb = "is";
            }

            $stats{learn}++;
            my $also = 0;
            if ( $tidbit =~ s/^<(action|reply)>\s*// ) {
                $verb = "<$1>";
            } elsif ( $verb eq 'is also' ) {
                $also = 1;
                $verb = 'is';
            } elsif ($forced) {
                $bag{forced} = 1;
                if ( $verb ne '<action>' and $verb ne '<reply>' ) {
                    $verb =~ s/^<|>$//g;
                }

                if ( $fact =~ s/ is also$// ) {
                    $also = 1;
                } else {
                    $fact =~ s/ is$//;
                }
            }
            $fact = &trim($fact);

            if (    &config("your_mom_is")
                and not $bag{op}
                and $verb eq 'is'
                and rand(100) < &config("your_mom_is") )
            {
                $tidbit =~ s/\W+$//;
                &say( $bag{chl} => "$bag{who}: Your mom is $tidbit!" );
                return;
            }

            if ( lc $fact eq lc $bag{who} or lc $fact eq lc "$bag{who} quotes" )
            {
                Log "Not allowing $bag{who} to edit his own factoid";
                &say( $bag{chl} =>
                      "Please don't edit your own factoids, $bag{who}." );
                return;
            }

            $fact = &decommify($fact);
            Log "Learning '$fact' '$verb' '$tidbit'";
            &sql(
                'select id, tidbit from bucket_facts
                  where fact = ? and verb = "<alias>"',
                [$fact],
                {
                    %bag,
                    fact    => $fact,
                    verb    => $verb,
                    tidbit  => $tidbit,
                    cmd     => "unalias",
                    db_type => "SINGLE",
                }
            );

            return;
        } elsif (
            $bag{orig} =~ m{ ^ \s* (how|what|whom?|where|why) # interrogative
                                   \s+ does
                                   \s+ (\S+) # nick
                                   \s+ (\w+) # verb
                                   (?:.*) # more }xi
          )
        {
            my ( $inter, $member, $verb, $more ) = ( $1, $2, $3, $4 );
            if ( &DEBUG or $irc->is_channel_member( $bag{chl}, $member ) ) {
                Log "Looking up $member($verb) + $more";
                &lookup(
                    %bag,
                    editable => 0,
                    msg      => $member,
                    orig     => $member,
                    verb     => &s_form($verb),
                    starts   => $more,
                );

                return;
            }
        } elsif ( $bag{addressed}
            and $bag{orig} =~ m{[+\-*%/]}
            and $bag{orig} =~ m{^([\s0-9a-fA-F_x+\-*%/.()]+)$} )
        {

            # Mathing!
            $stats{math}++;
            my $res;
            my $exp = $1;

         # if there's hex in here, but not prefixed with 0x, just throw an error
            foreach my $num ( $exp =~ /([x0-9a-fA-F.]+)/g ) {
                next if $num =~ /^0x|^[0-9.]+$|^[0-9.]+[eE][0-9]+$/;
                &error( $bag{chl}, $bag{who} );
                return;
            }

            if ( $exp !~ /\*\*/ and $math ) {
                my $newexp;
                foreach my $word ( split /( |-[\d_e.]+|\*\*|[+\/%()*])/, $exp )
                {
                    $word = "new $math(\"$word\")" if $word =~ /^[_0-9.e]+$/;
                    $newexp .= $word;
                }
                $exp = $newexp;
            }
            $exp = "package Bucket::Eval; \$res = 0 + $exp;";
            Log " -> $exp";
            eval $exp;
            Log "-> $res";
            if ( defined $res ) {
                if ( length $res < 400 ) {
                    &say( $bag{chl} => "$bag{who}: $res" );
                } else {
                    $res->accuracy(400);
                    &say(   $bag{chl} => "$bag{who}: "
                          . $res->mantissa() . "e"
                          . $res->exponent() );
                }
            } elsif ($@) {
                $@ =~ s/ at \(.*//;
                &say( $bag{chl} => "Sorry, $bag{who}, there was an error: $@" );
            } else {
                &error( $bag{chl}, $bag{who} );
            }
            return;
        } elsif ( $bag{addressed} ) {
            &error( $bag{chl}, $bag{who} );
            return;
        }

        #Log "extra work on $bag{msg}";
        if ( $bag{orig} =~ /^say (.*)/i ) {
            my $msg = $1;
            $stats{say}++;
            $msg =~ s/\W+$//;
            $msg .= "!";
            &say( $bag{chl} => ucfirst $msg );
        } elsif ( $bag{orig} =~ /^(?:Do you|Does anyone) know (\w+)/i
            and $1 !~ /who|of|if|why|where|what|when|whose|how/i )
        {
            $stats{hum}++;
            &say( $bag{chl} => "No, but if you hum a few bars I can fake it" );
        } elsif ( &config("max_sub_length")
            and length( $bag{orig} ) < &config("max_sub_length")
            and $bag{orig} =~ s/(\w+)-ass (\w+)/$1 ass-$2/ )
        {
            $stats{ass}++;
            &say( $bag{chl} => $bag{orig} );
        } elsif ( &config("max_sub_length")
            and length( $bag{orig} ) < &config("max_sub_length")
            and rand(100) < &config("the_fucking")
            and $bag{orig} =~ s/\bthe fucking\b/fucking the/ )
        {
            $stats{fucking}++;
            &say( $bag{chl} => $bag{orig} );
        } elsif (
            &config("max_sub_length")
            and length( $bag{orig} ) < &config("max_sub_length")
            and $bag{orig} !~ /extra|except/
            and rand(100) < &config("ex_to_sex")
            and (  $bag{orig} =~ s/\ban ex/a sex/
                or $bag{orig} =~ s/\bex/sex/ )
          )
        {
            $stats{sex}++;
            if ( $bag{type} eq 'irc_ctcp_action' ) {
                &do( $bag{chl} => $bag{orig} );
            } else {
                &say( $bag{chl} => $bag{orig} );
            }
        } elsif (
            $bag{orig} !~ /\?\s*$/
            and $bag{editable}
            and $bag{orig} =~ /^(?:
                               puts \s (\S.+) \s in \s (the \s)? $nick\b
                             | (?:gives|hands) \s $nick \s (\S.+)
                             | (?:gives|hands) \s (\S.+) \s to $nick\b
                            )/ix
            or (
                    $bag{addressed}
                and $bag{orig} =~ /^(?:
                                 take \s this \s (\S.+)
                               | have \s (an? \s \S.+)
                              )/x
            )
          )
        {
            my $item = ( $1 || $2 || $3 );
            $item =~ s/\b(?:his|her|their)\b/$bag{who}\'s/;
            $item =~ s/[ .?!]+$//;
            $item =~ s/\$+([a-zA-Z])/$1/g;

            my ( $rc, @dropped ) = &put_item( $item, 0 );
            if ( $rc == 1 ) {
                &cached_reply( $bag{chl}, $bag{who}, $item, "takes item" );
            } elsif ( $rc == 2 ) {
                &cached_reply( $bag{chl}, $bag{who}, [ $item, @dropped ],
                    "pickup full" );
            } elsif ( $rc == -1 ) {
                &cached_reply( $bag{chl}, $bag{who}, $item, "duplicate item" );
                return;
            } else {
                Log "&put_item($item) returned weird value: $rc";
                return;
            }

            Log "Taking $item from $bag{who}: " . join ", ", @inventory;
            &sql(
                'insert ignore into bucket_items (what, user, channel)
                         values (?, ?, ?)',
                [ $item, $bag{who}, $bag{chl} ]
            );
            &random_item_cache( $_[KERNEL] );
        } else {    # lookup band name!
            if (    &config("band_name")
                and $bag{type} eq 'irc_public'
                and rand(100) < &config("band_name")
                and $bag{orig} !~ m{https?://}i )
            {
                my $name = $bag{orig};
                my $nicks = join "|", map { "\Q$_" } $irc->nicks();
                $nicks = qr/(?:^|\b)(?:$nicks)(?:\b|$)/i;
                $name =~ s/^$nicks://;
                unless ( $name =~ s/$nicks//g ) {
                    $name =~ s/[^\- \w']+//g;
                    $name =~ s/^\s+|\s+$//g;
                    $name =~ s/\s\s+/ /g;
                    my $stripped_name = $name;
                    $stripped_name =~ s/'//g;
                    my @words = split( ' ', $stripped_name );
                    if (    length $name <= 32
                        and @words == 3
                        and $name !~ /\b[ha]{2,}\b/i )
                    {
                        &sql(
                            'select value
                              from bucket_values left join bucket_vars
                                   on bucket_vars.id = bucket_values.var_id
                              where name = "band" and value = ?
                              limit 1',
                            [$stripped_name],
                            {
                                %bag,
                                name          => $name,
                                stripped_name => $stripped_name,
                                words         => \@words,
                                cmd           => "band_name",
                                db_type       => 'SINGLE',
                            }
                        );
                    }
                }
            }
        }
    } elsif ( $bag{cmd} eq 'create_var' ) {
        if ( $res->{INSERTID} ) {
            $replacables{$bag{var}}{id} = $res->{INSERTID};
            Log "ID for $bag{var}: $res->{INSERTID}";
        } else {
            Log "ERR: create_var called without an INSERTID!";
        }
    } elsif ( $bag{cmd} eq 'load_gender' ) {
        my %line = ref $res->{RESULT} ? %{$res->{RESULT}} : ();
        $stats{users}{genders}{lc $bag{nick}} =
          lc( $line{gender} || "androgynous" );
    } elsif ( $bag{cmd} eq 'load_vars' ) {
        my @lines = ref $res->{RESULT} ? @{$res->{RESULT}} : [];
        my ( @small, @large );
        foreach my $line (@lines) {
            if ( $line->{num} > &config("value_cache_limit") ) {
                push @large, $line->{name};
            } else {
                push @small, $line->{name};
            }
        }
        Log "Small vars: @small";
        Log "Large vars: @large";

        if (@small) {

            # load the smaller variables
            &sql(
                'select vars.id id, name, perms, type, value
                  from bucket_vars vars
                       left join bucket_values vals
                       on vars.id = vals.var_id
                  where name in (' . join( ",", map { "?" } @small ) . ')
                  order by vars.id',
                \@small,
                {cmd => "load_vars_cache", db_type => 'MULTIPLE'},
            );
        }

        # make note of the larger variables, and preload a cache
        foreach my $var (@large) {
            &sql(
                'select vars.id id, name, perms, type, value
                  from bucket_vars vars
                       left join bucket_values vals
                       on vars.id = vals.var_id
                  where name = ?
                  order by rand()
                  limit 10',
                [$var],
                {cmd => "load_vars_large", db_type => 'MULTIPLE'}
            );
        }
    } elsif ( $bag{cmd} eq 'load_vars_large' ) {
        my @lines = ref $res->{RESULT} ? @{$res->{RESULT}} : [];

        Log "Loading large replacables: $lines[0]{name}";
        foreach my $line (@lines) {
            unless ( exists $replacables{$line->{name}} ) {
                $replacables{$line->{name}} = {
                    cache => [],
                    perms => $line->{perms},
                    id    => $line->{id},
                    type  => $line->{type}
                };
            }

            push @{$replacables{$line->{name}}{cache}}, $line->{value};
        }
    } elsif ( $bag{cmd} eq 'load_vars_cache' ) {
        my @lines = ref $res->{RESULT} ? @{$res->{RESULT}} : [];

        Log "Loading small replacables";
        foreach my $line (@lines) {
            unless ( exists $replacables{$line->{name}} ) {
                $replacables{$line->{name}} = {
                    vals  => [],
                    perms => $line->{perms},
                    id    => $line->{id},
                    type  => $line->{type}
                };
            }

            push @{$replacables{$line->{name}}{vals}}, $line->{value};
        }

        Log "Loaded vars:",
          &make_list(
            map { "$_ (" . scalar @{$replacables{$_}{vals}} . ")" }
            sort keys %replacables
          );
    } elsif ( $bag{cmd} eq 'dump_var' ) {
        unless ( ref $res->{RESULT} ) {
            &say( $bag{chl} => "Sorry, $bag{who}, something went wrong!" );
            return;
        }

        my $url = &config("www_url") . "/" . uri_escape("var_$bag{name}.txt");
        if ( open( DUMP, ">", &config("www_root") . "/var_$bag{name}.txt" ) ) {
            my $count = 0;
            foreach ( @{$res->{RESULT}} ) {
                print DUMP "$_->{value}\n";
                $count++;
            }
            close DUMP;
            &say( $bag{chl} =>
                  "$bag{who}: Here's the full list ( $count ): $url" );
        } else {
            &say( $bag{chl} =>
                  "Sorry, $bag{who}, failed to dump out $bag{name}: $!" );
        }
    } elsif ( $bag{cmd} eq 'band_name' ) {
        my %line = ref $res->{RESULT} ? %{$res->{RESULT}} : ();
        unless ( $line{value} ) {
            &check_band_name( \%bag );
        }
    } elsif ( $bag{cmd} eq 'edit' ) {
        my @lines = ref $res->{RESULT} ? @{$res->{RESULT}} : [];

        unless (@lines) {
            &error( $bag{chl}, $bag{who} );
            return;
        }

        if ( $lines[0]->{protected} and not $bag{op} ) {
            Log "$bag{who}: that factoid is protected";
            &say( $bag{chl} => "Sorry, $bag{who}, that factoid is protected" );
            return;
        }

        my ( $gflag, $iflag );
        $gflag = ( $bag{op} and $bag{flag} =~ s/g//g );
        $iflag = ( $bag{flag} =~ s/i//g ? "i" : "" );
        my $count = 0;
        $undo{$bag{chl}} = [
            'edit', $bag{who},
            [],     "$lines[0]->{fact} =~ s/$bag{old}/$bag{new}/"
        ];

        foreach my $line (@lines) {
            my $fact = "$line->{verb} $line->{tidbit}";
            $fact = "$line->{verb} $line->{tidbit}" if $line->{verb} =~ /<.*>/;
            if ($gflag) {
                my $c;
                next unless $c = $fact =~ s/(?$iflag:\Q$bag{old}\E)/$bag{new}/g;
                $count += $c;
            } else {
                next unless $fact =~ s/(?$iflag:\Q$bag{old}\E)/$bag{new}/;
            }

            if ( $fact =~ /\S/ ) {
                my ( $verb, $tidbit );
                if ( $fact =~ /^<(\w+)>\s*(.*)/ ) {
                    ( $verb, $tidbit ) = ( "<$1>", $2 );
                } else {
                    ( $verb, $tidbit ) = split ' ', $fact, 2;
                }

                unless (
                    &validate_factoid(
                        {
                            %bag,
                            fact   => $fact,
                            verb   => $verb,
                            tidbit => $tidbit
                        }
                    )
                  )
                {
                    next;
                }

                $stats{edited}++;
                Report "$bag{who} edited $line->{fact}(#$line->{id})"
                  . " in $bag{chl}: New values: $fact";
                Log "$bag{who} edited $line->{fact}($line->{id}): "
                  . "New values: $fact";

                &sql(
                    'update bucket_facts set verb=?, tidbit=?
                       where id=? limit 1',
                    [ $verb, $tidbit, $line->{id} ],
                );
                push @{$undo{$bag{chl}}[2]},
                  [ 'update', $line->{id}, $line->{verb}, $line->{tidbit} ];
            } elsif ( $bag{op} ) {
                $stats{deleted}++;
                Report "$bag{who} deleted $line->{fact}($line->{id})"
                  . " in $bag{chl}: $line->{verb} $line->{tidbit}";
                Log "$bag{who} deleted $line->{fact}($line->{id}):"
                  . " $line->{verb} $line->{tidbit}";
                &sql(
                    'delete from bucket_facts where id=? limit 1',
                    [ $line->{id} ],
                );
                push @{$undo{$bag{chl}}[2]}, [ 'insert', {%$line} ];
            } else {
                &error( $bag{chl}, $bag{who} );
                Log "$bag{who}: $line->{fact} =~ s/// failed";
            }

            if ($gflag) {
                next;
            }
            &say( $bag{chl} => "Okay, $bag{who}, factoid updated." );

            if ( exists $fcache{lc $line->{fact}} ) {
                Log "Updating cache for '$line->{fact}'";
                &cache( $_[KERNEL], $line->{fact} );
            }
            return;
        }

        if ($gflag) {
            if ( $count == 1 ) {
                $count = "one match";
            } else {
                $count .= " matches";
            }
            &say( $bag{chl} => "Okay, $bag{who}; $count." );

            if ( exists $fcache{lc $bag{fact}} ) {
                Log "Updating cache for '$bag{fact}'";
                &cache( $_[KERNEL], $bag{fact} );
            }
            return;
        }

        &error( $bag{chl}, $bag{who} );
        Log "$bag{who}: $bag{fact} =~ s/// failed";
    } elsif ( $bag{cmd} eq 'forget' ) {
        my %line = ref $res->{RESULT} ? %{$res->{RESULT}} : ();
        unless ( keys %line ) {
            &error( $bag{chl}, $bag{who} );
            Log "Nothing to forget in '$bag{id}'";
            return;
        }

        $undo{$bag{chl}} = [ 'insert', $bag{who}, \%line ];
        Report "$bag{who} called forget to delete "
          . "'$line{fact}', '$line{verb}', '$line{tidbit}'";
        Log "forgetting $bag{fact}";
        &sql( 'delete from bucket_facts where id=?', [ $line{id} ], );
        &say(
            $bag{chl} => "Okay, $bag{who}, forgot that",
            "$line{fact} $line{verb} $line{tidbit}"
        );
    } elsif ( $bag{cmd} eq 'delete_id' ) {
        my %line = ref $res->{RESULT} ? %{$res->{RESULT}} : ();
        unless ( $line{fact} ) {
            &error( $bag{chl}, $bag{who} );
            Log "Nothing found in id $bag{fact}";
            return;
        }

        $undo{$bag{chl}} = [ 'insert', $bag{who}, \%line, $bag{fact} ];
        Report "$bag{who} deleted '$line{fact}' (#$bag{fact}) in $bag{chl}";
        Log "deleting $bag{fact}";
        &sql( 'delete from bucket_facts where id=?', [ $bag{fact} ], );
        &say( $bag{chl} => "Okay, $bag{who}, deleted "
              . "'$line{fact} $line{verb} $line{tidbit}'." );
    } elsif ( $bag{cmd} eq 'delete' ) {
        my @lines = ref $res->{RESULT} ? @{$res->{RESULT}} : ();
        unless (@lines) {
            &error( $bag{chl}, $bag{who} );
            Log "Nothing to delete in '$bag{fact}'";
            return;
        }

        $undo{$bag{chl}} = [ 'insert', $bag{who}, \@lines, $bag{fact} ];
        Report "$bag{who} deleted '$bag{fact}' in $bag{chl}";
        Log "deleting $bag{fact}";
        &sql( 'delete from bucket_facts where fact=?', [ $bag{fact} ], );
        my $s = "";
        $s = "s" unless @lines == 1;
        &say(   $bag{chl} => "Okay, $bag{who}, "
              . scalar @lines
              . " factoid$s deleted." );
    } elsif ( $bag{cmd} eq 'unalias' ) {
        my %line = ref $res->{RESULT} ? %{$res->{RESULT}} : ();
        my $fact = $bag{fact};
        if ( $line{id} ) {
            Log "Dealiased $fact => $line{tidbit}";
            $fact = $line{tidbit};
        }

        &sql(
            'select id from bucket_facts where fact = ? and tidbit = ?',
            [ $fact, $bag{tidbit} ],
            {%bag, fact => $fact, cmd => "learn1", db_type => 'SINGLE',}
        );
    } elsif ( $bag{cmd} eq 'learn1' ) {
        my %line = ref $res->{RESULT} ? %{$res->{RESULT}} : ();
        if ( $line{id} ) {
            &say( $bag{chl} => "$bag{who}: I already had it that way" );
            return;
        }

        &sql(
            'select protected from bucket_facts where fact = ?',
            [ $bag{fact} ],
            {%bag, cmd => "learn2", db_type => 'SINGLE',}
        );
    } elsif ( $bag{cmd} eq 'learn2' ) {
        my %line = ref $res->{RESULT} ? %{$res->{RESULT}} : ();
        if ( $line{protected} ) {
            if ( $bag{op} ) {
                unless ( $bag{forced} ) {
                    Log "$bag{who}: that factoid is protected (op, not forced)";
                    &say( $bag{chl} =>
                            "Sorry, $bag{who}, that factoid is protected.  "
                          . "Use <$bag{verb}> to override." );
                    return;
                }

                Log "$bag{who}: overriding protection.";
            } else {
                Log "$bag{who}: that factoid is protected";
                &say( $bag{chl} =>
                      "Sorry, $bag{who}, that factoid is protected" );
                return;
            }
        }

        unless ( &validate_factoid( \%bag ) ) {
            &say( $bag{chl} => "Sorry, $bag{who}, I can't do that." );
            return;
        }

        if ( lc $bag{verb} eq '<alias>' ) {
            &say( $bag{chl} => "$bag{who}, please use the 'alias' command." );
            return;
        }

        # we said 'is also' but we didn't get any existing results
        if ( $bag{also} and $res->{RESULT} ) {
            delete $bag{also};
        }

        &sql(
            'insert bucket_facts (fact, verb, tidbit, protected)
                     values (?, ?, ?, ?)',
            [ $bag{fact}, $bag{verb}, $bag{tidbit}, $line{protected} || 0 ],
            {%bag, cmd => "learn3"}
        );
    } elsif ( $bag{cmd} eq 'learn3' ) {
        if ( $res->{INSERTID} ) {
            $undo{$bag{chl}} = [
                'delete',         $bag{who},
                $res->{INSERTID}, "that '$bag{fact}' is '$bag{tidbit}'"
            ];

            $stats{last_fact}{$bag{chl}} = $res->{INSERTID};

            Report "$bag{who} taught in $bag{chl} (#$res->{INSERTID}):"
              . " '$bag{fact}', '$bag{verb}', '$bag{tidbit}'";
            Log "$bag{who} taught '$bag{fact}', '$bag{verb}', '$bag{tidbit}'";
        }
        my $ack;
        if ( $bag{also} ) {
            $ack = "Okay, $bag{who} (added as only factoid).";
        } else {
            $ack = "Okay, $bag{who}.";
        }

        if ( $bag{ack} ) {
            $ack = $bag{ack};
        }
        &say( $bag{chl} => $ack );

        if ( exists $fcache{lc $bag{fact}} ) {
            Log "Updating cache for '$bag{fact}'";
            &cache( $_[KERNEL], $bag{fact} );
        }
    } elsif ( $bag{cmd} eq 'merge' ) {
        my %line = ref $res->{RESULT} ? %{$res->{RESULT}} : ();
        Report "$bag{who} merged in $bag{chl} '$bag{src}' with '$bag{dst}'";
        Log "$bag{who} merged '$bag{src}' with '$bag{dst}'";
        if ( $line{id} and $line{verb} eq '<alias>' ) {
            &say( $bag{chl} => "Sorry, $bag{who}, those are already merged." );
            return;
        }

        if ( $line{id} ) {
            &sql( 'update ignore bucket_facts set fact=? where fact=?',
                [ $bag{dst}, $bag{src} ] );
            &sql( 'delete from bucket_facts where fact=?', [ $bag{src} ] );
        }

        &sql(
            'insert bucket_facts (fact, verb, tidbit, protected)
                     values (?, "<alias>", ?, 1)',
            [ $bag{src}, $bag{dst} ],
        );

        &say( $bag{chl} => "Okay, $bag{who}." );
        $undo{$bag{chl}} = ['merge'];
    } elsif ( $bag{cmd} eq 'alias1' ) {
        my %line = ref $res->{RESULT} ? %{$res->{RESULT}} : ();
        if ( $line{id} and $line{verb} ne '<alias>' ) {
            &say( $bag{chl} => "Sorry, $bag{who}, "
                  . "there is already a factoid for '$bag{src}'." );
            return;
        }

        Report "$bag{who} aliased in $bag{chl} '$bag{src}' to '$bag{dst}'";
        Log "$bag{who} aliased '$bag{src}' to '$bag{dst}'";
        &sql(
            'insert bucket_facts (fact, verb, tidbit, protected)
                     values (?, "<alias>", ?, 1)',
            [ $bag{src}, $bag{dst} ],
            {%bag, fact => $bag{src}, tidbit => $bag{dst}, cmd => "learn3"}
        );
    } elsif ( $bag{cmd} eq 'cache' ) {
        my @lines = ref $res->{RESULT} ? @{$res->{RESULT}} : [];
        $fcache{lc $bag{key}} = [];
        foreach my $line (@lines) {
            $fcache{lc $bag{key}} = [@lines];
        }
        Log "Cached " . scalar(@lines) . " factoids for $bag{key}";
    } elsif ( $bag{cmd} eq 'report' ) {
        my %line = ref $res->{RESULT} ? %{$res->{RESULT}} : ();

        if ( $line{id} ) {
            if ( keys %{$stats{last_vars}{$bag{chl}}} ) {
                my $report = Dumper( $stats{last_vars}{$bag{chl}} );
                $report =~ s/\n//g;
                $report =~ s/\$VAR1 = //;
                $report =~ s/  +/ /g;
                &say(   $bag{chl} => "$bag{who}: That was "
                      . ( $stats{last_alias_chain}{$bag{chl}} || "" )
                      . "'$line{fact}' "
                      . "(#$bag{id}): $line{verb} $line{tidbit};  "
                      . "vars used: $report." );
            } else {
                &say(   $bag{chl} => "$bag{who}: That was "
                      . ( $stats{last_alias_chain}{$bag{chl}} || "" )
                      . "'$line{fact}' "
                      . "(#$bag{id}): $line{verb} $line{tidbit}" );
            }
        } else {
            &say( $bag{chl} => "$bag{who}: No idea!" );
        }
    } elsif ( $bag{cmd} eq 'literal' ) {
        my @lines = ref $res->{RESULT} ? @{$res->{RESULT}} : [];

        unless (@lines) {
            if ( $bag{addressed} ) {
                &error( $bag{chl}, $bag{who}, "$bag{who}: " );
            }
            return;
        }

        if ( $bag{page} ne "*" and $bag{page} > 10 ) {
            $bag{page} = "*";
        }

        if ( $lines[0]->{verb} eq "<alias>" ) {
            my $new_fact = $lines[0]->{tidbit};
            &sql(
                'select id, verb, tidbit, mood, chance, protected from
                  bucket_facts where fact = ? order by id',
                [$new_fact],
                {
                    %bag,
                    cmd      => "literal",
                    alias_to => $new_fact,
                    db_type  => 'MULTIPLE',
                }
            );
            Report "Asked for the 'literal' of an alias,"
              . " being smart and redirecting to '$new_fact'";
            return;
        }

        if (    $bag{page} eq '*'
            and &config("www_url")
            and &config("www_root")
            and -w &config("www_root") )
        {
            my $url =
              &config("www_url") . "/" . uri_escape("literal_$bag{fact}.txt");
            Report
              "$bag{who} asked in $bag{chl} to dump out $bag{fact} -> $url";
            if (
                open( DUMP, ">", &config("www_root") . "/literal_$bag{fact}.txt"
                )
              )
            {
                if ( defined $bag{alias_to} ) {
                    print DUMP "Alias to $bag{alias_to}\n";
                }
                my $count = @lines;
                while ( my $fact = shift @lines ) {
                    if ( $bag{op} ) {
                        print DUMP "#$fact->{id}\t";
                    }

                    print DUMP join "\t", $fact->{verb}, $fact->{tidbit};
                    print DUMP "\n";
                }
                close DUMP;
                &say( $bag{chl} =>
                      "$bag{who}: Here's the full list ($count): $url" );
                return;
            } else {
                Log "Failed to write dump file: $!";
                &error( $bag{chl}, $bag{who} );
                return;
            }
        }

        $bag{page} = 1 if $bag{page} eq '*';

        my $prefix = "$bag{fact}";
        if ( $lines[0]->{protected} and not defined $bag{alias_to} ) {
            $prefix .= " (protected)";
        } elsif ( defined $bag{alias_to} ) {
            $prefix .= " (=> $bag{alias_to})";
        }

        my $answer;
        my $linelen = 400;
        while ( $bag{page}-- ) {
            $answer = "";
            while ( my $fact = shift @lines ) {
                my $bit;
                if ( $bag{op} ) {
                    $bit = "(#$fact->{id}) ";
                }
                $bit .= "$fact->{verb} $fact->{tidbit}";
                $bit =~ s/\|/\\|/g;
                if ( length("$prefix $answer|$bit") > $linelen and $answer ) {
                    unshift @lines, $fact;
                    last;
                }
                if ( $fact->{chance} ) {
                    $bit .= "[$fact->{chance}%]";
                }
                if ( $fact->{mood} ) {
                    my @moods = ( ":<", ":(", ":|", ":)", ":D" );
                    $bit .= "{$moods[$fact->{mood}/20]}";
                }

                $answer = join "|", ( $answer ? $answer : () ), $bit;
            }
        }

        if (@lines) {
            $answer .= "|" . @lines . " more";
        }
        &say( $bag{chl} => "$prefix $answer" );
    } elsif ( $bag{cmd} eq 'stats1' ) {
        $stats{triggers} = $res->{RESULT}{c};
    } elsif ( $bag{cmd} eq 'stats2' ) {
        $stats{rows} = $res->{RESULT}{c};
    } elsif ( $bag{cmd} eq 'stats3' ) {
        $stats{items}        = $res->{RESULT}{c};
        $stats{stats_cached} = time;
    } elsif ( $bag{cmd} eq 'itemcache' ) {
        @random_items =
          ref $res->{RESULT} ? map { $_->{what} } @{$res->{RESULT}} : [];
        Log "Updated random item cache: ", join ", ", @random_items;

        if ( $stats{preloaded_items} ) {
            if ( @random_items > $stats{preloaded_items} ) {
                @inventory =
                  splice( @random_items, 0, $stats{preloaded_items}, () );
            } else {
                @inventory    = @random_items;
                @random_items = ();
            }
            delete $stats{preloaded_items};

            &random_item_cache( $_[KERNEL] );
        }
    } elsif ( $bag{cmd} eq 'tla' ) {
        if ( $res->{RESULT}{value} ) {
            $stats{lookup_tla}++;
            $bag{tla} =~ s/\W//g;
            $stats{last_fact}{$bag{chl}} = "a possible meaning of $bag{tla}.";
            &say(
                $bag{chl} => "$bag{who}: " . join " ",
                map { ucfirst }
                  split ' ', $res->{RESULT}{value}
            );
        }
    }
}

sub irc_start {
    Log "DB Connect...";
    $_[KERNEL]->post(
        db       => 'CONNECT',
        DSN      => &config("db_dsn"),
        USERNAME => &config("db_username"),
        PASSWORD => &config("db_password"),
        EVENT    => 'db_success',
    );

    $irc->yield( register => 'all' );
    $_[HEAP]->{connector} = POE::Component::IRC::Plugin::Connector->new();
    $irc->plugin_add( Connector => $_[HEAP]->{connector} );

    # find out which variables should be preloaded
    &sql(
        'select name, count(value) num
          from bucket_vars vars
               left join bucket_values
               on vars.id = var_id
          group by name', undef,
        {cmd => "load_vars", db_type => 'MULTIPLE'}
    );

    foreach my $reply (
        "Don't know",
        "takes item",
        "drops item",
        "pickup full",
        "list items",
        "duplicate item",
        "band name reply",
        "tumblr name reply",
        "haiku detected",
        "uses reply"
      )
    {
        &cache( $_[KERNEL], $reply );
    }
    &random_item_cache( $_[KERNEL] );
    $stats{preloaded_items} = &config("inventory_preload");

    $irc->yield(
        connect => {
            Nick     => $nick,
            Username => &config("username") || "bucket",
            Ircname  => &config("irc_name") || "YABI",
            Server   => &config("server") || "irc.foonetic.net",
            Port     => &config("port") || "6667",
            Flood    => 0,
            UseSSL   => &config("ssl") || 0,
            useipv6  => &config("ipv6") || 0
        }
    );

    if ( &config("bucketlog") and -f &config("bucketlog") and open BLOG,
        &config("bucketlog") )
    {
        seek BLOG, 0, SEEK_END;
    }

    $_[KERNEL]->delay( heartbeat => 10 );

    return if &signal_plugin( "start", {} );
}

sub irc_on_notice {
    my ($who) = split /!/, $_[ARG0];
    my $msg = $_[ARG2];

    Log("Notice from $who: $msg");

    return if &signal_plugin( "on_notice", {who => $who, msg => $msg} );

    return if $stats{identified};
    if (
        lc $who eq lc &config("nickserv_nick")
        and $msg =~ (
              &config("nickserv_msg")
            ? &config("nickserv_msg")
            : qr/Password accepted|(?:isn't|not) registered|You are now identified/
        )
      )
    {
        Log("Identified, joining $channel");
        $irc->yield( mode => $nick => &config("user_mode") );
        unless ( &config("hide_hostmask") ) {
            $irc->yield( mode => $nick => "-x" );
        }

        $irc->yield( join => $channel );
        $stats{identified} = 1;
    }
}

sub irc_on_nick {
    my ($who) = split /!/, $_[ARG0];
    my $newnick = $_[ARG1];

    return if &signal_plugin( "on_nick", {who => $who, newnick => $newnick} );

    return unless exists $stats{users}{genders}{lc $who};
    $stats{users}{genders}{lc $newnick} =
      delete $stats{users}{genders}{lc $who};
    &sql( "update genders set nick=? where nick=? limit 1",
        [ $newnick, $who ] );
    &load_gender($newnick);
}

sub irc_on_jointopic {
    my ( $chl, $topic ) = @{$_[ARG2]}[ 0, 1 ];
    $topic =~ s/ ARRAY\(0x\w+\)$//;

    return if &signal_plugin( "jointopic", {chl => $chl, topic => $topic} );
}

sub irc_on_join {
    my ($who) = split /!/, $_[ARG0];

    return if &signal_plugin( "on_join", {who => $who} );

    return if exists $stats{users}{genders}{lc $who};

    &load_gender($who);
}

sub irc_on_chan_sync {
    my $chl = $_[ARG0];
    Log "Sync done for $chl";

    return if &signal_plugin( "on_chan_sync", {chl => $chl} );

    if ( not &DEBUG and $chl eq $channel ) {
        Log("Autojoining channels");
        foreach my $chl ( &config("logchannel"), keys %{$config->{autojoin}} ) {
            $irc->yield( join => $chl );
            Log("... $chl");
        }
    }
}

sub irc_on_connect {
    Log("Connected...");

    return if &signal_plugin( "on_connect", {} );

    if ( &config("identify_before_autojoin") ) {
        Log("Identifying...");
        &say( nickserv => "identify $pass" );
    } else {
        Log("Skipping identify...");
        $stats{identified} = 1;
        $irc->yield( join => $channel );
    }
    Log("Done.");
}

sub irc_on_disconnect {
    Log("Disconnected...");

    return if &signal_plugin( "on_disconnect", {} );

    close LOG;
    $irc->call( unregister => 'all' );
    exit;
}

sub save {
    DumpFile( $configfile, $config );
}

sub error {
    my ( $chl, $who, $prefix ) = @_;
    &cached_reply( $chl, $who, $prefix, "don't know" );
}

sub inventory {
    return "nothing" unless @inventory;

    return &make_list(@inventory);
}

sub cached_reply {
    my ( $chl, $who, $extra, $type ) = @_;
    my $line = $fcache{$type}[ rand( @{$fcache{$type}} ) ];
    Log "cached '$type' reply: $line->{verb} $line->{tidbit}";

    my $tidbit = $line->{tidbit};

    if ( $type eq 'band name reply' ) {
        if ( $tidbit =~ /\$band/i ) {
            $tidbit =~ s/\$band/$extra/ig;
        }

        $extra = "";
    } elsif ( $type eq 'tumblr name reply' ) {
        $extra =~ s/[^a-z0-9]+//ig;
        $extra = lc $extra;
        if ( $tidbit =~ /\$band/i ) {
            $tidbit =~ s/\$band/$extra/ig;
        }

        $extra = "";
    } elsif ( $type eq 'pickup full'
        or $type eq 'drops item' )
    {
        $extra = [$extra] unless ref $extra eq 'ARRAY';
        my $newitem;
        my @olditems = @$extra;
        $newitem = shift @olditems if $type eq 'pickup full';

        my $olditems = &make_list(@olditems);
        if ( $tidbit =~ /\$item/i ) {
            $tidbit =~ s/\$item/$newitem/ig;
        }
        if ( $tidbit =~ /\$giveitem/i ) {
            $tidbit =~ s/\$giveitem/$olditems/ig;
        }
    } elsif ( $type eq 'takes item'
        or $type eq 'duplicate item'
        or $type eq 'list items' )
    {
        if ( $tidbit =~ /\$item/i ) {
            $tidbit =~ s/\$item/$extra/ig;
        }

        if ( $tidbit =~ /\$inventory/i ) {
            $tidbit =~ s/\$inventory/&inventory/eg;
        }

        $extra = "";
    }

    $tidbit = &expand( $who, $chl, $tidbit, 0, undef );
    return unless $tidbit;

    if ( $line->{verb} eq '<action>' ) {
        &do( $chl => $tidbit );
    } elsif ( $line->{verb} eq '<reply>' ) {
        &say( $chl => $tidbit );
    } else {
        $extra ||= "";
        &say( $chl => "$extra$tidbit" );
    }
}

sub cache {
    my ( $kernel, $key ) = @_;
    &sql( 'select verb, tidbit from bucket_facts where fact = ?',
        [$key], {cmd => "cache", key => $key, db_type => 'MULTIPLE'} );
}

sub get_stats {
    my ($kernel) = @_;

    Log "Updating stats";
    &sql( 'select count(distinct fact) c from bucket_facts',
        undef, {cmd => 'stats1', db_type => 'SINGLE'} );
    &sql( 'select count(id) c from bucket_facts',
        undef, {cmd => 'stats2', db_type => 'SINGLE'} );
    &sql( 'select count(id) c from bucket_items',
        undef, {cmd => 'stats3', db_type => 'SINGLE'} );

    $stats{last_updated} = time;

    # check if the log file was moved, if so, reopen it
    if ( &config("logfile") and not -f &config("logfile") ) {
        &open_log;
        Log "Reopened log file";
    }
}

sub tail {
    my $kernel = shift;

    my $time = 1;
    while (<BLOG>) {
        chomp;
        s/^[\d-]+ [\d:]+ //;
        s/from [\d.]+ //;
        Report $time++, $_;
    }
    seek BLOG, 0, SEEK_CUR;
}

sub heartbeat {
    $_[KERNEL]->delay( heartbeat => 60 );

    return if &signal_plugin( "heartbeat", {} );

    if ( my $file_input = &config("file_input") ) {
        rename $file_input, "$file_input.processing";
        if ( open FI, "$file_input.processing" ) {
            while (<FI>) {
                chomp;
                my ( $output, $who, $msg ) = split ' ', $_, 3;
                $msg =~ s/\s\s+/ /g;
                $msg =~ s/^\s+|\s+$//g;
                $msg = &trim($msg);

                Log "file input: $output, $who: $msg";

                if ( $msg eq 'something random' ) {
                    &lookup(
                        editable  => 0,
                        addressed => 1,
                        chl       => $output,
                        who       => &someone($channel),
                    );
                } else {
                    &lookup(
                        editable  => 0,
                        addressed => 1,
                        chl       => $output,
                        who       => $who,
                        msg       => $msg,
                    );
                }
            }

            close FI;
        }
        unlink "$file_input.processing";
    }

    my $chl = &DEBUG ? $channel : $mainchannel;
    $last_activity{$chl} ||= time;

    return
      if &config("random_wait") == 0
      or time - $last_activity{$chl} < 60 * &config("random_wait");

    return if $stats{last_idle_time}{$chl} > $last_activity{$chl};

    $stats{last_idle_time}{$chl} = time;

    my %sources = (
        MLIA => [
            "http://feeds.feedburner.com/mlia", qr/MLIA.*/,
            "feedburner:origLink"
        ],
        SMDS => [
            "http://twitter.com/statuses/user_timeline/62581962.rss",
            qr/^shitmydadsays: "|"$/, "link"
        ],
        FAPSB => [
            "http://twitter.com/statuses/user_timeline/83883736.rss",
            qr/^FakeAPStylebook: /, "link"
        ],
        FAF => [
            "http://twitter.com/statuses/user_timeline/14062390.rss",
            qr/^fakeanimalfacts: |http:.*/, "link"
        ],
        Batman => [
            "http://twitter.com/statuses/user_timeline/126881128.rss",
            qr/^God_Damn_Batman: |http:.*/, "link"
        ],
        factoid => 1
    );
    my $source = &config("idle_source");

    if ( $source eq 'random' ) {
        $source = ( keys %sources )[ rand keys %sources ];
    }

    $stats{chatter_source}{$source}++;

    if ( $source ne 'factoid' ) {
        Log "Looking up $source story";
        my ( $story, $url ) = &read_rss( @{$sources{$source}} );
        if ($story) {
            &say( $chl => $story );
            $stats{last_fact}{$chl} = $url;
            return;
        }
    }

    &lookup(
        chl          => $chl,
        who          => $nick,
        idle         => 1,
        exclude_verb => [ split( ',', &config("random_exclude_verbs") ) ],
    );
}

sub trim {
    my $msg = shift;

    $msg =~ s/[^\w+]+$// if $msg !~ /^[^\w+]+$/;
    $msg =~ s/\\(.)/$1/g;

    return $msg;
}

sub get_item {
    my $give = shift;

    my $item = rand @inventory;
    if ($give) {
        Log "Dropping $inventory[$item]";
        return splice( @inventory, $item, 1, () );
    } else {
        return $inventory[$item];
    }
}

sub someone {
    my $channel = shift;
    my @exclude = @_;
    my %nicks   = map { lc $_ => $_ } keys %{$stats{users}{$channel}};

    # we're never someone
    delete $nicks{$nick};

    # ignore people who asked to be excluded
    if ( ref $config->{exclude} ) {
        delete @nicks{map { lc } keys %{$config->{exclude}}};
    }

    # if we were supplied additional nicks to ignore, remove them
    foreach my $exclude (@exclude) {
        delete $nicks{$exclude};
    }

    return 'someone' unless keys %nicks;
    return ( values %nicks )[ rand( keys %nicks ) ];
}

sub clear_cache {
    foreach my $channel ( keys %{$stats{users}} ) {
        next if $channel !~ /^#/;
        foreach my $user ( keys %{$stats{users}{$channel}} ) {
            delete $stats{users}{$channel}{$user}
              if $stats{users}{$channel}{$user}{last_active} <
              time - &config("user_activity_timeout");
        }
    }

    foreach my $chl ( keys %{$stats{last_talk}} ) {
        foreach my $user ( keys %{$stats{last_talk}{$chl}} ) {
            if ( not $stats{last_talk}{$chl}{$user}{when}
                or $stats{last_talk}{$chl}{$user}{when} >
                &config("user_activity_timeout") )
            {
                if ( $stats{last_talk}{$chl}{$user}{count} > 20 ) {
                    Report "Clearing flood flag for $user in $chl";
                }
                delete $stats{last_talk}{$chl}{$user};
            }
        }
    }
}

sub random_item_cache {
    my $kernel = shift;
    my $force  = shift;
    my $limit  = &config("random_item_cache_size");
    $limit =~ s/\D//g;

    if ( not $force and @random_items >= $limit ) {
        return;
    }

    &sql( "select what, user from bucket_items order by rand() limit $limit",
        undef, {cmd => "itemcache", db_type => 'MULTIPLE'} );
}

# here's the story.  put_item is called either when someone hands us a new
# item, or when a new item is crafted.  When handed items, we just refuse to go
# over the inventory_size, dropping at least one item before accepting the new
# one.
# But, crafted items can push us over the inventory_size to double that.  If a
# crafted item hits the hard limit (2x), do NOT accept it, instead, just drop.
# return values:
# -1 - duplicate item
# 1  - item accepted
# 2  - items dropped.  for handed items, the item has also been accepted.
sub put_item {
    my $item    = shift;
    my $crafted = shift;

    my $dup = 0;
    foreach my $inv_item (@inventory) {
        if ( lc $inv_item eq lc $item ) {
            $dup = 1;
            last;
        }
    }

    if ($dup) {
        return -1;
    } else {
        if (   ( $crafted and @inventory >= 2 * &config("inventory_size") )
            or ( not $crafted and @inventory >= &config("inventory_size") ) )
        {

            my $dropping_rate = &config("item_drop_rate");
            my @drop;
            while ( @inventory >= &config("inventory_size")
                and $dropping_rate-- > 0 )
            {
                push @drop, &get_item(1);
            }

            unless ($crafted) {
                push @inventory, $item;
            }

            return ( 2, @drop );
        } else {
            push @inventory, $item;
            return 1;
        }
    }
}

sub make_list {
    my @list = @_;

    return "[none]" unless @list;
    return $list[0] if @list == 1;
    return join " and ", @list if @list == 2;
    my $last = $list[-1];
    return join( ", ", @list[ 0 .. $#list - 1 ] ) . ", and $last";
}

sub s {
    return $_[0] == 1 ? "" : "s";
}

sub commify {
    my $num = shift;
    1 while ( $num =~ s/(\d)(\d\d\d)\b/$1,$2/ );
    return $num;
}

sub decommify {
    my $string = shift;

    $string =~ s/\s*,\s*/ /g;
    $string =~ s/\s\s+/ /g;

    return $string;
}

sub round_time {
    my $dt    = shift;
    my $units = "second";

    if ( $dt > 60 ) {
        $dt /= 60;    # minutes
        $units = "minute";

        if ( $dt > 60 ) {
            $dt /= 60;    # hours
            $units = "hour";

            if ( $dt > 24 ) {
                $dt /= 24;    # days
                $units = "day";

                if ( $dt > 7 ) {
                    $dt /= 7;    # weeks
                    $units = "week";
                }
            }
        }
    }
    $dt = int($dt);

    $units .= &s($dt);

    return ( $dt, $units );
}

sub say {
    my $chl  = shift;
    my $text = "@_";

    my %data = ( chl => $chl, text => $text );
    return if &signal_plugin( "say", \%data );
    ( $chl, $text ) = ( $data{chl}, $data{text} );

    if ( $chl =~ m#^/# ) {
        Log "Writing to '$chl'";
        if ( open FO, ">>", $chl ) {
            print FO "S $text\n";
            close FO;
        } else {
            Log "Failed to write to $chl: $!";
        }
        return;
    }

    $irc->yield( privmsg => $chl => $text );
}

sub say_long {
    my $chl  = shift;
    my $text = "@_";

    while ( length($text) > 300 and $text =~ s/(.{0,300})\s+(.*)/$2/ ) {
        &say( $chl, $1 );
    }
    &say( $chl, $text ) if $text =~ /\S/;
}

sub do {
    my $chl    = shift;
    my $action = "@_";

    my %data = ( chl => $chl, text => $action );
    return if &signal_plugin( "do", \%data );
    ( $chl, $action ) = ( $data{chl}, $data{text} );

    if ( $chl =~ m#^/# ) {
        if ( open FO, ">>", $chl ) {
            print FO "D $action\n";
            close FO;
        } else {
            Log "Failed to write to $chl: $!";
        }
        return;
    }

    $irc->yield( ctcp => $chl => "ACTION $action" );
}

sub load_gender {
    my $who = shift;

    Log "Looking up ${who}'s gender...";
    &sql( 'select gender from genders where nick = ? limit 1',
        [$who], {cmd => 'load_gender', nick => $who, db_type => 'SINGLE'} );
}

sub lookup {
    my %params = @_;
    my $sql;
    my $type;
    my @placeholders;

    return if &signal_plugin( "lookup", \%params );

    if ( exists $params{msg} ) {
        $sql          = "fact = ?";
        $type         = "single";
        $params{msg}  = &decommify( $params{msg} );
        @placeholders = ( $params{msg} );
    } elsif ( exists $params{msgs} ) {
        $sql = "fact in (" . join( ", ", map { "?" } @{$params{msgs}} ) . ")";
        @placeholders = map { &decommify($_) } @{$params{msgs}};
        $type = "multiple";
    } else {
        $sql  = "1";
        $type = "none";
    }

    if ( exists $params{verb} ) {
        $sql .= " and verb = ?";
        push @placeholders, $params{verb};
    } elsif ( exists $params{exclude_verb} ) {
        $sql .= " and verb not in ("
          . join( ", ", map { "?" } @{$params{exclude_verb}} ) . ")";
        push @placeholders, @{$params{exclude_verb}};
    }

    if ( $params{starts} ) {
        $sql .= " and tidbit like ?";
        push @placeholders, "$params{starts}\%";
    } elsif ( $params{search} ) {
        $sql .= " and tidbit like ?";
        push @placeholders, "\%$params{search}\%";
    }

    &sql(
        "select id, fact, verb, tidbit from bucket_facts
          where $sql order by rand(" . int( rand(1e6) ) . ') limit 1',
        \@placeholders,
        {
            %params,
            cmd       => "fact",
            orig      => $params{orig} || $params{msg},
            addressed => $params{addressed} || 0,
            editable  => $params{editable} || 0,
            op        => $params{op} || 0,
            type      => $params{type} || "irc_public",
            db_type   => 'SINGLE',
        }
    );
}

sub sql {
    my ( $sql, $placeholders, $baggage ) = @_;

    my $type = $baggage->{db_type} || "DO";
    delete $baggage->{db_type};

    POE::Kernel->post(
        db    => $type,
        SQL   => $sql,
        EVENT => 'db_success',
        $placeholders ? ( PLACEHOLDERS => $placeholders ) : (),
        $baggage      ? ( BAGGAGE      => $baggage )      : (),
    );
}

sub expand {
    my ( $who, $chl, $msg, $editable, $to ) = @_;

    my $gender = $stats{users}{genders}{lc $who};
    my $target = $who;
    while ( $msg =~ /(?<!\\)(\$who\b|\${who})/i ) {
        my $cased = &set_case( $1, $who );
        last unless $msg =~ s/(?<!\\)(?:\$who\b|\${who})/$cased/i;
        $stats{last_vars}{$chl}{who} = $who;
    }

    if ( $msg =~ /(?<!\\)(?:\$someone\b|\${someone})/i ) {
        $stats{last_vars}{$chl}{someone} = [];
        while ( $msg =~ /(?<!\\)(\$someone\b|\${someone})/i ) {
            my $rnick = &someone( $chl, $who, defined $to ? $to : () );
            my $cased = &set_case( $1, $rnick );
            last unless $msg =~ s/\$someone\b|\${someone}/$cased/i;
            push @{$stats{last_vars}{$chl}{someone}}, $rnick;

            $gender = $stats{users}{genders}{lc $rnick};
            $target = $rnick;
        }
    }

    while ( $msg =~ /(?<!\\)(\$to\b|\${to})/i ) {
        unless ( defined $to ) {
            $to = &someone( $chl, $who );
        }
        my $cased = &set_case( $1, $to );
        last unless $msg =~ s/(?<!\\)(?:\$to\b|\${to})/$cased/i;
        push @{$stats{last_vars}{$chl}{to}}, $to;

        $gender = $stats{users}{genders}{lc $to};
        $target = $to;
    }

    $stats{last_vars}{$chl}{item} = [];
    while ( $msg =~ /(?<!\\)(\$(give)?item|\${(give)?item})/i ) {
        my $giveflag = $2 || $3 ? "give" : "";
        if (@inventory) {
            my $give  = $editable && $giveflag;
            my $item  = &get_item($give);
            my $cased = &set_case( $1, $item );
            push @{$stats{last_vars}{$chl}{item}},
              $give ? "$item (given)" : $item;
            last
              unless $msg =~
              s/(?<!\\)(?:\$${giveflag}item|\${${giveflag}item})/$cased/i;
        } else {
            $msg =~
              s/(?<!\\)(?:\$${giveflag}item|\${${giveflag}item})/bananas/i;
            push @{$stats{last_vars}{$chl}{item}}, "(bananas)";
        }
    }
    delete $stats{last_vars}{$chl}{item}
      unless @{$stats{last_vars}{$chl}{item}};

    $stats{last_vars}{$chl}{newitem} = [];
    while ( $msg =~ /(?<!\\)(\$(new|get)item|\${(new|get)item})/i ) {
        my $keep = lc( $2 || $3 );
        if ($editable) {
            my $newitem = shift @random_items || 'bananas';
            if ( $keep eq 'new' ) {
                my ( $rc, @dropped ) = &put_item( $newitem, 1 );
                if ( $rc == 2 ) {
                    $stats{last_vars}{$chl}{dropped} = \@dropped;
                    &cached_reply( $chl, $who, \@dropped, "drops item" );
                    return;
                }
            }

            if (@random_items <= &config("random_item_cache_size") / 2) {
              # force a cache update
              Log "Random item cache running low, forcing an update.";
              $stats{last_updated} = 0;
            }

            my $cased = &set_case( $1, $newitem );
            last
              unless $msg =~
              s/(?<!\\)(?:\$${keep}item|\${${keep}item})/$cased/i;
            push @{$stats{last_vars}{$chl}{newitem}}, $newitem;
        } else {
            $msg =~ s/(?<!\\)(?:\$${keep}item|\${${keep}item})/bananas/ig;
        }
    }
    delete $stats{last_vars}{$chl}{newitem}
      unless @{$stats{last_vars}{$chl}{newitem}};

    if ($gender) {
        foreach my $gvar ( keys %gender_vars ) {
            next unless $msg =~ /(?<!\\)(?:\$$gvar\b|\${$gvar})/i;

            Log "Replacing gvar $gvar...";
            if ( exists $gender_vars{$gvar}{$gender} ) {
                my $g_v = $gender_vars{$gvar}{$gender};
                Log " => $g_v";
                if ( $g_v =~ /%N/ ) {
                    $g_v =~ s/%N/$target/;
                    Log " => $g_v";
                }
                while ( $msg =~ /(?<!\\)(\$$gvar\b|\${$gvar})/i ) {
                    my $cased = &set_case( $1, $g_v );
                    last unless $msg =~ s/\Q$1/$cased/g;
                }
                $stats{last_vars}{$chl}{$gvar} = $g_v;
            } else {
                Log "Can't find gvar for $gvar->$gender!";
            }
        }
    }

    my $oldmsg = "";
    $stats{last_vars}{$chl} = {};
    while ( $oldmsg ne $msg
        and $msg =~ /(?<!\\)(?:\$([a-zA-Z_]\w+)|\${([a-zA-Z_]\w+)})/ )
    {
        $oldmsg = $msg;
        my $var = $1 || $2;
        Log "Found variable \$$var";

        # yay for special cases!
        my $conjugate;
        my $record = $replacables{lc $var};
        my $full   = $var;
        if ( not $record and $var =~ s/ed$//i ) {
            $record = $replacables{lc $var};
            if ( $record and $record->{type} eq 'verb' ) {
                $conjugate = \&past;
                Log "Special case *ed";
            } else {
                undef $record;
                $var = $full;
            }
        }

        if ( not $record and $var =~ s/ing$//i ) {
            $record = $replacables{lc $var};
            if ( $record and $record->{type} eq 'verb' ) {
                $conjugate = \&gerund;
                Log "Special case *ing";
            } else {
                undef $record;
                $var = $full;
            }
        }

        if ( not $record and $var =~ s/s$//i ) {
            $record = $replacables{lc $var};
            if ( $record and $record->{type} eq 'verb' ) {
                $conjugate = \&s_form;
                Log "Special case *s (verb)";
            } elsif ( $record and $record->{type} eq 'noun' ) {
                $conjugate = \&PL_N;
                Log "Special case *s (noun)";
            } else {
                undef $record;
                $var = $full;
            }
        }

        unless ($record) {
            Log "Can't find a record for \$$var";
            last;
        }

        $stats{last_vars}{$chl}{$full} = []
          unless exists $stats{last_vars}{$chl}{$full};
        Log "full = $full, msg = $msg";
        while ( $msg =~ /((\ban? )?(?<!\\)\$(?:$full|{$full})(?:\b|$))/i ) {
            my $replacement = &get_var( $record, $var, $conjugate );
            $replacement = &set_case( $var, $replacement );
            $replacement = A($replacement) if $2;

            if ( exists $record->{cache} and not @{$record->{cache}} ) {
                Log "Refilling cache for $full";
                &sql(
                    'select vars.id id, name, perms, type, value
                      from bucket_vars vars
                           left join bucket_values vals
                           on vars.id = vals.var_id
                      where name = ?
                      order by rand()
                      limit 20',
                    [$full],
                    {cmd => "load_vars_large", db_type => 'MULTIPLE'}
                );
            }

            if ( $2 and substr( $2, 0, 1 ) eq 'A' ) {
                $replacement = ucfirst $replacement;
            }

            Log "Replacing $1 with $replacement";
            last if $replacement =~ /\$/;

            $msg =~
              s/(?:\ban? )?(?<!\\)\$(?:$full|{$full})(?:\b|$)/$replacement/i;
            push @{$stats{last_vars}{$chl}{$full}}, $replacement;
        }

        Log " => $msg";
    }

    return $msg;
}

sub set_case {
    my ( $var, $value ) = @_;

    my $case;
    $var =~ s/\W+//g;
    if ( $var =~ /^[A-Z_]+$/ ) {
        $case = "U";
    } elsif ( $var =~ /^[A-Z][a-z_]+$/ ) {
        $case = "u";
    } else {
        $case = "l";
    }

    # values that already include capitals are never modified
    if ( $value =~ /[A-Z]/ or $case eq "l" ) {
        return $value;
    } elsif ( $case eq 'U' ) {
        return uc $value;
    } elsif ( $case eq 'u' ) {
        return join " ", map { ucfirst } split ' ', $value;
    }
}

sub get_var {
    my ( $record, $var, $conjugate ) = @_;

    $var = lc $var;

    return "\$$var" unless $record->{vals} or $record->{cache};
    my @values =
      exists $record->{vals}
      ? @{$record->{vals}}
      : ( shift @{$record->{cache}} );
    return "\$$var" unless @values;
    my $value = $values[ rand @values ];
    $value =~ s/\$//g;

    if ( ref $conjugate eq 'CODE' ) {
        Log "Conjugating $value ($conjugate)";
        Log join ", ", "past=" . \&past, "s_form=" . \&s_form,
          "gerund=" . \&gerund;
        $value = $conjugate->($value);
        Log " => $value";
    }

    return $value;
}

sub read_rss {
    my ( $url, $re, $tag ) = @_;

    eval {
        require LWP::Simple;
        import LWP::Simple qw/$ua/;
        require XML::Simple;

        $LWP::Simple::ua->agent("Bucket/$nick");
        $LWP::Simple::ua->timeout(10);
        my $rss = LWP::Simple::get($url);
        if ($rss) {
            Log "Retrieved RSS";
            my $xml = XML::Simple::XMLin($rss);
            for ( 1 .. 5 ) {
                if ( $xml and my $story = $xml->{channel}{item}[ rand(40) ] ) {
                    $story->{description} =
                      HTML::Entities::decode_entities( $story->{description} );
                    $story->{description} =~ s/$re//isg if $re;
                    next if $url =~ /twitter/ and $story->{description} =~ /^@/;
                    next if length $story->{description} > 400;
                    next if $story->{description} =~ /\[\.\.\.\]/;

                    return ( $story->{description}, $story->{$tag} );
                }
            }
        }
    };

    if ($@) {
        Report "Failed when trying to read RSS from $url: $@";
        return ();
    }
}

sub get_band_name_handles {
    if ( exists $handles{dbh} ) {
        return \%handles;
    }

    Log "Creating band name database/query handles";
    unless ( $handles{dbh} ) {
        $handles{dbh} =
          DBI->connect( &config("db_dsn"), &config("db_username"),
            &config("db_password") )
          or Report "Failed to create dbh!" and return undef;
    }

    $handles{lookup} = $handles{dbh}->prepare(
        "select id, word, `lines`
         from word2id
         where word in (?, ?, ?)
         order by `lines`"
    );

    return \%handles;
}

sub check_band_name {
    my $bag = shift;

    my $handles = &get_band_name_handles();
    return unless $handles;

    return unless ref $bag->{words} eq 'ARRAY' and @{$bag->{words}} == 3;
    $bag->{start} = time;
    my @trimmed_words = map { s/[^0-9a-zA-Z'\-]//g; lc $_ } @{$bag->{words}};
    if (   $trimmed_words[0] eq $trimmed_words[1]
        or $trimmed_words[0] eq $trimmed_words[2]
        or $trimmed_words[1] eq $trimmed_words[2] )
    {
        return;
    }

    Log "Executing band name word count (@trimmed_words)";
    $handles->{lookup}->execute(@trimmed_words);
    my @words;
    my $delayed;
    my $found = 0;
    while ( my $line = $handles->{lookup}->fetchrow_hashref ) {
        my $entry = {
            word  => $line->{word},
            id    => $line->{id},
            count => $line->{lines},
            start => time
        };

        if ( @words < 2 ) {
            Log "processing $entry->{word} ($entry->{count})\n";
            $entry->{sth} = $handles->{dbh}->prepare(
                "select line
                 from word2line
                 where word = ?
                 order by line"
            );
            $entry->{sth}->execute( $entry->{id} );
            $entry->{cur} = $entry->{sth}->fetchrow_hashref;
            unless ( $entry->{cur} ) {
                Log "Not all words found, new band declared";
                $bag->{elapsed} = time - $bag->{start};
                &add_new_band($bag);
                return;
            }
            $entry->{next_id} = $entry->{cur}{line};
            $entry->{elapsed} = time - $entry->{start};
            push @words, $entry;
        } else {
            Log "delaying processing $entry->{word} ($entry->{count})\n";
            $delayed = $entry;
        }
    }

    @words = sort { $a->{next_id} <=> $b->{next_id} } @words;

    my @union;
    Log "Finding union";
    while (1) {
        unless ( $words[0]->{next_id} and $words[1]->{next_id} ) {
            &add_new_band($bag);
            return;
        }

        if ( $words[0]->{next_id} == $words[1]->{next_id} ) {
            push @union, $words[0]->{next_id};
        }

        unless ( $words[0]->{next_id} < $words[1]->{next_id} ) {
            ( $words[1], $words[0] ) = ( $words[0], $words[1] );
        }

        unless ($words[0]->{sth}
            and $words[0]->{cur} = $words[0]->{sth}->fetchrow_hashref )
        {
            last;
        }
        $words[0]->{next_id} = $words[0]->{cur}{line};
    }

    if ( @union > 0 ) {
        Log "Union ids: " . @union;
        my $sth =
          $handles->{dbh}->prepare(
                "select line from word2line where word = ?  and line in (?"
              . ( ",?" x ( @union - 1 ) )
              . ") limit 1" );

        my $res = $sth->execute( $delayed->{id}, @union );
        $found = $res > 0;
    } else {
        $found = 1;
    }

    Log "Found = $found";
    unless ($found) {
        $bag->{elapsed} = time - $bag->{start};
        &add_new_band($bag);
        return;
    }
}

sub add_new_band {
    my $bag = shift;
    &sql(
        'insert into bucket_values (var_id, value)
         values ( (select id from bucket_vars where name = ? limit 1), ?);',
        [ &config("band_var"), $bag->{stripped_name} ],
        {%$bag, cmd => "new band name"}
    );

    $bag->{name} =~ s/(^| )(\w)/$1\u$2/g;
    Report "Learned a new band name from $bag->{who} in $bag->{chl} ("
      . join( " ", &round_time( $bag->{elapsed} ) )
      . "): $bag->{name}";
    if ( &config("tumblr_name") > rand(100) ) {
        &cached_reply( $bag->{chl}, $bag->{who}, $bag->{name},
            "tumblr name reply" );
    } else {
        &cached_reply( $bag->{chl}, $bag->{who}, $bag->{name},
            "band name reply" );
    }
}

sub config {
    my ( $key, $val ) = @_;

    if ( defined $val ) {
        return $config->{$key} = $val;
    }

    if ( defined $config->{$key} ) {
        return $config->{$key};
    } elsif ( exists $config_keys{$key} ) {
        return $config_keys{$key}[1];
    } else {
        return undef;
    }
}

sub open_log {
    if ( &config("logfile") ) {
        my $logfile =
          &DEBUG ? &config("logfile") . ".debug" : &config("logfile");
        open( LOG, ">>", $logfile )
          or die "Can't write " . &config("logfile") . ": $!";
        Log("Opened $logfile");
        print STDERR scalar localtime, " - @_\n";
        print STDERR "Logfile opened: $logfile.\n";
    }
}

sub load_plugin {
    my $name = shift;

    unless ( &config("plugin_dir") ) {
        Log("Plugin directory not defined, can't load plugins.");
        return 0;
    }

    # make sure there's no funny business in the plugin name (like .., etc)
    $name =~ s/\W+//g;

    Log("Loading plugin: $name");
    if ( exists $stats{loaded_plugins}{$name} ) {
        &unload_plugin($name);
    }

    unless ( open PLUGIN, "<", &config("plugin_dir") . "/plugin.$name.pl" ) {
        Log(
            "Can't find plugin.$name.pl in " . &config("plugin_dir") . ": $!" );
        return 0;
    }

    # enable slurp mode
    local $/;
    my $code = <PLUGIN>;
    close PLUGIN;

    unless ( $code =~ /^# BUCKET PLUGIN/ ) {
        Log("Invalid plugin format.");
        return 0;
    }

    my $package = "Bucket::Plugin::$name";
    eval join ";", "{",
      "package $package",
      'use lib "' . &config("plugin_dir") . '"',
      $code,
      "}";
    if ($@) {
        Log("Error loading plugin: $@");
        return 0;
    }

    my @signals;
    eval { @signals = "$package"->signals(); };
    if ($@) {
        Log("Error loading plugin signals: $@");
    } elsif (@signals) {
        Log("Registering signals: @signals");
        foreach my $signal (@signals) {
            &register( $name, $signal );
        }
    }

    my @commands;
    eval { @commands = "$package"->commands(); };
    if ($@) {
        Log("Error loading plugin commands: $@");
    } elsif (@commands) {
        Log( "Registering commands: ",
            &make_list( map { $_->{label} } @commands ) );
        foreach my $command (@commands) {
            $command->{plugin} = $name;
            push @registered_commands, $command;
        }
    }

    my %plugin_settings;
    eval { %plugin_settings = "$package"->settings(); };
    if ($@) {
        Log("Error loading plugin settings: $@");
    } elsif (%plugin_settings) {
        Log( "Defined settings: ", &make_list( sort keys %plugin_settings ) );
        while ( my ( $key, $value ) = each %plugin_settings ) {
            $config_keys{$key} = $value;
        }
    }

    &signal_plugin( "onload", {name => $name} );

    $stats{loaded_plugins}{$name} = "@signals";

    return 1;
}

sub unload_plugin {
    my $name = shift;

    Log("Unloading plugin: $name");
    &unregister( $name, "*" );

    @registered_commands = grep { $_->{plugin} ne $name } @registered_commands;

    delete $stats{loaded_plugins}{$name};
}

sub signal_plugin {
    my ( $sig_name, $data ) = @_;
    my $rc = 0;

   # call each registered plugin, in the order they were registered. First the
   # plugins that ask for specific signals, then the ones that want all signals.

    # The return value from the plugin can control future processing. A true
    # value (positive or negative) means no further processing will be done in
    # the core. If the return value is negative, no further plugins will be
    # called.

    if ( exists $plugin_signals{$sig_name} ) {
        foreach my $plugin ( @{$plugin_signals{$sig_name}} ) {
            eval {
                $data->{rc}{plugin} =
                  "Bucket::Plugin::$plugin"->route( $sig_name, $data );
            };
            $rc ||= $data->{rc}{plugin};

            if ($@) {
                Log("Error when signalling $sig_name to $plugin: $@");
            }

            last if $rc < 0;
        }
    }

    return $rc if $rc < 0;

    if ( exists $plugin_signals{"*"} ) {
        foreach my $plugin ( @{$plugin_signals{"*"}} ) {
            eval {
                $data->{rc}{plugin} =
                  "Bucket::Plugin::$plugin"->route( $sig_name, $data );
            };
            $rc ||= $data->{rc}{plugin};

            if ($@) {
                Log("Error when signalling $sig_name to $plugin: $@");
            }

            last if $rc < 0;
        }
    }

    return $rc;
}

sub register {
    my ( $name, $signal ) = @_;

    Log("Registering plugin $name for $signal signals");
    unless ( exists $plugin_signals{$signal} ) {
        $plugin_signals{$signal} = [];
    }

    if ( grep { $_ eq $name } @{$plugin_signals{$signal}} ) {
        Log("Already registered!");
    } else {
        push @{$plugin_signals{$signal}}, $name;
    }
}

sub unregister {
    my ( $name, $signal ) = @_;

    Log("Unregistering plugin $name from $signal signals");
    unless ( exists $plugin_signals{$signal} ) {
        $plugin_signals{$signal} = [];
    }

    my @signals = ($signal);
    if ( $signal eq "*" ) {
        @signals = keys %plugin_signals;
    }

    foreach my $sig (@signals) {
        if ( grep { $_ eq $name } @{$plugin_signals{$sig}} ) {
            $plugin_signals{$sig} =
              [ grep { $_ ne $name } @{$plugin_signals{$sig}} ];
        }
    }
}

sub talking {

    # == 0 - shut up by operator
    # == -1 - talking
    # > 0 - shut up by user, until time()
    my ( $chl, $set ) = @_;

    if ($set) {
        return $_talking{$chl} = $set;
    } else {
        $_talking{$chl} = -1 unless exists $_talking{$chl};
        $_talking{$chl} = -1
          if ( $_talking{$chl} > 0 and $_talking{$chl} < time );
        return $_talking{$chl};
    }
}

sub validate_factoid {
    my $bag = shift;

    return 1 if $bag->{op};

    if ( &config("var_limit") > 0 ) {
        my $l = &config("var_limit");
        if ( $bag->{tidbit} =~ /(?:(?<!\\)\$[a-zA-Z_].+){$l}/ ) {
            Report("Too many variables in $bag->{tidbit}");
            return 0;
        }
    }

    return 1;
}

# vim: set sw=4
