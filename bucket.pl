#!/usr/bin/perl -w
#  Copyright (C) 2009  Dan Boger - zigdon+bot@gmail.com
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
use YAML qw/LoadFile DumpFile/;
use Data::Dumper;
use Fcntl qw/:seek/;
use HTML::Entities;
$Data::Dumper::Indent = 1;

use constant { DEBUG => 0 };

# work around a bug: https://rt.cpan.org/Ticket/Display.html?id=50991
sub s_form { return Lingua::EN::Conjugate::s_form(@_); }

my $VERSION = '$Id: bucket.pl 685 2009-08-04 19:15:15Z dan $';

$SIG{CHLD} = 'IGNORE';

$|++;

### IRC portion
my $configfile = "/home/bucket/bucket.yml";
my $config     = LoadFile($configfile);
my $nick       = $config->{nick} || "Bucket";
my $pass       = $config->{password} || "somethingsecret";
$nick = DEBUG ? ( $config->{debug_nick} || "bucketgoat" ) : $nick;
my $channel =
  DEBUG
  ? ( $config->{debug_channel} || "#bucket" )
  : ( $config->{controll_channel} || "#billygoat" );
my ($irc) = POE::Component::IRC::State->spawn();
my %channels = ( $channel => 1 );
my $mainchannel = $config->{main_channel} || "#xkcd";
my %talking;
my %fcache;
my %stats;
my %undo;
my %last_activity;
my @inventory;
my @random_items;
my %replacables;
my %history;

my %config_keys = (
    bananas_chance         => "p",
    band_name              => "p",
    ex_to_sex              => "p",
    history_size           => "i",
    idle_source            => "s",
    increase_mute          => "i",
    inventory_preload      => "i",
    inventory_size         => "i",
    item_drop_rate         => "i",
    random_item_cache_size => "i",
    random_wait            => "i",
    user_activity_timeout  => "i",
    your_mom_is            => "p",
    www_root               => "s",
    www_url                => "s",
);

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
    posessive => {
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

# set up gender aliases
foreach my $type ( keys %gender_vars ) {
    foreach my $alias ( @{ $gender_vars{$type}{aliases} } ) {
        $gender_vars{$alias} = $gender_vars{$type};
        &Log("Setting gender alias: $alias => $type");
    }
}

$stats{startup_time} = time;

if ( $config->{logfile} ) {
    open( LOG, ">>$config->{logfile}" )
      or die "Can't write $config->{logfile}: $!";
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
        check_idle       => \&check_idle,
    },
);

POE::Kernel->run;
print "POE::Kernel has left the building.\n";

sub Log {
    print scalar localtime, " - @_\n";
    if ( $config->{logfile} ) {
        print LOG scalar localtime, " - @_\n";
    }
}

sub Report {
    my $delay = shift if $_[0] =~ /^\d+$/;
    my $logchannel = DEBUG ? $channel : $config->{logchannel};
    unshift @_, "REPORT:" if DEBUG;

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

    $stats{topics}{$chl}{old}     = $stats{topics}{$chl}{current};
    $stats{topics}{$chl}{current} = $topic;
}

sub irc_on_kick {
    my ($kicker) = split /!/, $_[ARG0];
    my $chl      = $_[ARG1];
    my $kickee   = $_[ARG2];
    my $desc     = $_[ARG3];

    Log "$kicker kicked $kickee from $chl";

    &lookup(
        msgs => [ "$kicker kicked $kickee", "$kicker kicked someone" ],
        chl  => $chl,
        who  => $kicker,
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

    if ( not $stats{tail_time} or time - $stats{tail_time} > 60 ) {
        &tail( $_[KERNEL] );
        $stats{tail_time} = time;
    }

    $last_activity{$chl} = time;

    if ( exists $config->{ignore}{ lc $who } ) {

        Log("ignoring $who");
        return;
    }

    if ( $config->{history_size} and $config->{history_size} > 0 ) {
        push @{ $history{$chl} }, [ $who, $type, $msg ];

        if ( @{ $history{$chl} } > $config->{history_size} ) {
            shift @{ $history{$chl} };
        }
    }

    # keep track of who's active in each channel
    $stats{users}{$chl}{$who} = time;

    unless ( exists $stats{users}{genders}{ lc $who } ) {
        &load_gender($who);
    }

    my $operator = 0;
    if (   $irc->is_channel_operator( $channel, $who )
        or $irc->is_channel_owner( $channel, $who )
        or $irc->is_channel_admin( $channel, $who )
        or $irc->is_channel_operator( $mainchannel, $who )
        or $irc->is_channel_owner( $mainchannel, $who )
        or $irc->is_channel_admin( $mainchannel, $who ) )
    {
        $operator = 1;
    }

    my $addressed = 0;
    if ( $type eq 'irc_msg' or $msg =~ s/^$nick[:,]\s*|,\s+$nick\W+$//i ) {
        $addressed = 1;
    } else {
        $msg =~ s/^\S+://;
    }

    $msg =~ s/^\s+|\s+$//g;

    # == 0 - shut up by operator
    # == -1 - talking
    # > 0 - shut up by user, until time()
    $talking{$chl} = -1 unless exists $talking{$chl};
    $talking{$chl} = -1 if ( $talking{$chl} > 0 and $talking{$chl} < time );
    unless ( $talking{$chl} == -1 or ( $operator and $addressed ) ) {
        if ( $addressed and $config->{increase_mute} and $talking{$chl} > 0 ) {
            $talking{$chl} += $config->{increase_mute};
            Report "Shutting up longer in $chl - "
              . ( $talking{$chl} - time )
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
        $chl = $who;
    }

    if ( $config->{bananas_chance}
        and rand(100) < $config->{bananas_chance} )
    {
        &say( $chl => "Bananas!" );
    }

    my $editable = 0;
    $editable = 1
      if ( $type eq 'irc_public' and $chl ne '#bots' )
      or ( $type eq 'irc_msg' and $operator );
    Log("$type($chl): $who(o=$operator, a=$addressed, e=$editable): $msg");

    if (
            $editable
        and $msg =~ m{ (.*?)         # $1 key to edit
                   \s+(?:=~|~=)\s+   # match operator
                   s/                # start match
                     (               # $2 - string to replace
                      (?:
                        \\/ |        # escaped slashes are ok
                        [^/]         # anything but a slash
                      )+
                     )               # end of $2
                   /                 # separator
                    (.*)             # $3 - text to replace with
                   /
                   ([gi]*)           # $4 - i/g flags
                   \s* $             # trailing spaces
                 }x
      )
    {
        my ( $fact, $old, $new, $flag ) = ( $1, $2, $3, $4 );
        Report "$who is editing $fact in $chl: replacing '$old' with '$new'";
        Log "Editing $fact: replacing '$old' with '$new'";
        $_[KERNEL]->post(
            db  => 'MULTIPLE',
            SQL => 'select * ' . 'from bucket_facts where fact = ? order by id',
            PLACEHOLDERS => [$fact],
            BAGGAGE      => {
                cmd   => "edit",
                who   => $who,
                chl   => $chl,
                fact  => $fact,
                old   => $old,
                'new' => $new,
                flag  => $flag,
                op    => $operator,
            },
            EVENT => 'db_success'
        );
    } elsif (
        $msg =~ m{ (.*?)             # $1 key to look up
                   \s+(?:=~|~=)\s+   # match operator
                   /                 # start match
                     (               # $2 - string to replace
                      (?:
                        \\/ |        # escaped slashes are ok
                        [^/]         # anything but a slash
                      )+
                     )               # end of $2
                   /                 # separator
            }x
      )
    {
        my ( $fact, $search ) = ( $1, $2 );
        $search =~ s{([\\/%?"'])}{\\$1}g;
        $fact = &trim($fact);
        $msg =~ s/ =~ \/$search\///;
        Log "Looking up a particular factoid - '$search' in '$fact'";
        &lookup(
            chl       => $chl,
            msg       => $msg,
            who       => $who,
            addressed => $addressed,
            editable  => $editable,
            op        => $operator,
            search    => $search,
        );
    } elsif ( $msg =~ /^literal(?:\[([*\d]+)\])?\s+(.*)/i ) {
        my ( $page, $fact ) = ( $1 || 1, $2 );
        $stats{literal}++;
        $fact = &trim($fact);
        Log "Literal[$page] $fact";
        $_[KERNEL]->post(
            db  => 'MULTIPLE',
            SQL => 'select id, verb, tidbit, mood, chance, protected
                                from bucket_facts where fact = ? order by id',
            PLACEHOLDERS => [$fact],
            BAGGAGE      => {
                cmd  => "literal",
                who  => $who,
                chl  => $chl,
                page => $page,
                fact => $fact,
                op   => $operator,
            },
            EVENT => 'db_success'
        );
    } elsif ( $addressed and $operator and $msg =~ /^delete (#)?(.*)/i ) {
        my $id   = $1;
        my $fact = $2;
        $stats{deleted}++;

        if ($id) {
            $_[KERNEL]->post(
                db  => "SINGLE",
                SQL => "select fact, tidbit, verb, RE, protected, mood, chance
                                       from bucket_facts where id = ?",
                PLACEHOLDERS => [$fact],
                EVENT        => "db_success",
                BAGGAGE      => {
                    cmd  => "delete_id",
                    chl  => $chl,
                    who  => $who,
                    fact => $fact,
                }
            );
        } else {
            $_[KERNEL]->post(
                db  => "MULTIPLE",
                SQL => "select fact, tidbit, verb, RE, protected, mood, chance
                                       from bucket_facts where fact = ?",
                PLACEHOLDERS => [$fact],
                EVENT        => "db_success",
                BAGGAGE      => {
                    cmd  => "delete",
                    chl  => $chl,
                    who  => $who,
                    fact => $fact,
                }
            );
        }
    } elsif (
        $addressed
        and $msg =~ /^(?:shut \s up | go \s away)
                      (?: \s for \s (\d+)([smh])?|
                          \s for \s a \s (bit|moment|while|min(?:ute)?))?[.!]?$/xi
      )
    {
        $stats{shutup}++;
        my ( $num, $unit, $word ) = ( $1, lc $2, lc $3 );
        if ($operator) {
            my $target = 0;
            unless ( $num or $word ) {
                $num = 4 * 60 * 60;    # by default, shut up for 4 hours
            }
            if ($num) {
                $target += $num if not $unit or $unit eq 's';
                $target += $num * 60           if $unit eq 'm';
                $target += $num * 60 * 60      if $unit eq 'h';
                $target += $num * 60 * 60 * 24 if $unit eq 'd';
                Report
                  "Shutting up in $chl at ${who}'s request for $target seconds";
                &say( $chl => "Okay $who.  I'll be back later" );
                $talking{$chl} = time + $target;
            } elsif ($word) {
                $target += 60 if $word eq 'min' or $word eq 'minute';
                $target += 30 + int( rand(60) )           if $word eq 'moment';
                $target += 4 * 60 + int( rand( 4 * 60 ) ) if $word eq 'bit';
                $target += 30 * 60 + int( rand( 30 * 60 ) ) if $word eq 'while';
                Report
                  "Shutting up in $chl at ${who}'s request for $target seconds";
                &say( $chl => "Okay $who.  I'll be back later" );
                $talking{$chl} = time + $target;
            }
        } else {
            &say( $chl => "Okay, $who - be back in a bit!" );
            $talking{$chl} = time + $config->{timeout};
        }
    } elsif ( $addressed
        and $operator
        and $msg =~ /^unshut up\W*$|^come back\W*$/i )
    {
        &say( $chl => "\\o/" );
        $talking{$chl} = -1;
    } elsif ( $addressed and $operator and $msg =~ /^(join|part) (#\w+)/i ) {
        my ( $cmd, $dst ) = ( $1, $2 );
        unless ($dst) {
            &say( $chl => "$who: $cmd what channel?" );
            return;
        }
        $irc->yield( $cmd => $dst );
        &say( $chl => "$who: ${cmd}ing $dst" );
        Report "${cmd}ing $dst at ${who}'s request";
    } elsif ( $addressed and $operator and lc $msg eq 'list ignored' ) {
        &say(
            $chl => "Currently ignored: ",
            join ", ", sort keys %{ $config->{ignore} }
        );
    } elsif ( $addressed and $operator and $msg =~ /^(un)?ignore (\S+)/i ) {
        Report "$who is $1ignoring $2";
        if ($1) {
            delete $config->{ignore}{ lc $2 };
        } else {
            $config->{ignore}{ lc $2 } = 1;
        }
        &save;
        &say( $chl => "Okay, $who.  Ignore list updated." );
    } elsif ( $addressed and $operator and $msg =~ /^(un)?exclude (\S+)/i ) {
        Report "$who is $1excluding $2";
        if ($1) {
            delete $config->{exclude}{ lc $2 };
        } else {
            $config->{exclude}{ lc $2 } = 1;
        }
        &save;
        &say( $chl => "Okay, $who.  Exclude list updated." );
    } elsif ( $addressed and $operator and $msg =~ /^(un)?protect (.+)/i ) {
        my ( $protect, $fact ) = ( ( $1 ? 0 : 1 ), $2 );
        Report "$who is $1protecting $fact";
        Log "$1protecting $fact";

        if ( $fact =~ s/^\$// ) {    # it's a variable!
            unless ( exists $replacables{ lc $fact } ) {
                &say( $chl => "Sorry, $who, \$$fact isn't a valid variable." );
                return;
            }

            $replacables{ lc $fact }{perms} =
              $protect ? "read-only" : "editable";
        } else {
            $_[KERNEL]->post(
                db  => "DO",
                SQL => 'update bucket_facts set protected=? where fact=?',
                PLACEHOLDERS => [ $protect, $fact ],
                EVENT        => "db_success",
            );
        }
        &say( $chl => "Okay, $who, updated the protection bit." );
    } elsif ( $operator
        and $addressed
        and $msg =~ /^restore topic(?: (#\S+))?/ )
    {
        my $tchl = $1 || $chl;
        unless ( $stats{topics}{$tchl}{old} ) {
            &say( $chl =>
                  "Sorry, $who, I don't know what was the earlier topic!" );
            return;
        }
        Log "$who restored topic in $tchl: $stats{topics}{$tchl}{old}";
        &say( $chl => "Okay, $who." );
        $irc->yield( topic => $tchl => $stats{topics}{$tchl}{old} );
    } elsif ( $addressed and $msg =~ /^undo last(?: (#\S+))?/ ) {
        Log "$who called undo:";
        my $uchannel = $1 || $chl;
        my $undo = $undo{$uchannel};
        unless ( $operator or $undo->[1] eq $who ) {
            &say( $chl => "Sorry, $who, you can't undo that." );
            return;
        }
        Log Dumper $undo;
        if ( $undo->[0] eq 'delete' ) {
            $_[KERNEL]->post(
                db           => "DO",
                SQL          => 'delete from bucket_facts where id=? limit 1',
                PLACEHOLDERS => [ $undo->[2] ],
                EVENT        => "db_success",
            );
            Report "$who called undo: deleted $undo->[3].";
            &say( $chl => "Okay, $who, deleted $undo->[3]." );
            delete $undo{$uchannel};
        } elsif ( $undo->[0] eq 'insert' ) {
            if ( $undo->[2] and ref $undo->[2] eq 'ARRAY' ) {
                foreach my $entry ( @{ $undo->[2] } ) {
                    my %old = %$entry;
                    $old{RE}        = 0 unless $old{RE};
                    $old{protected} = 0 unless $old{protected};
                    $_[KERNEL]->post(
                        db  => "DO",
                        SQL => 'insert bucket_facts 
                                (fact, verb, tidbit, protected, RE, mood, chance)
                                values(?, ?, ?, ?, ?, ?, ?)',
                        PLACEHOLDERS => [
                            @old{ qw/fact verb tidbit protected RE mood chance/
                              }
                        ],
                        EVENT => "db_success",
                    );
                }
                Report "$who called undo: undeleted $undo->[3].";
                &say( $chl => "Okay, $who, undeleted $undo->[3]." );
            } elsif ( $undo->[2] and ref $undo->[2] eq 'HASH' ) {
                my %old = %{ $undo->[2] };
                $old{RE}        = 0 unless $old{RE};
                $old{protected} = 0 unless $old{protected};
                $_[KERNEL]->post(
                    db  => "DO",
                    SQL => 'insert bucket_facts 
                            (id, fact, verb, tidbit, protected, RE, mood, chance)
                            values(?, ?, ?, ?, ?, ?, ?, ?)',
                    PLACEHOLDERS => [
                        @old{qw/id fact verb tidbit protected RE mood chance/}
                    ],
                    EVENT => "db_success",
                );
                Report "$who called undo:",
                  "unforgot $old{fact} $old{verb} $old{tidbit}.";
                &say( $chl =>
                      "Okay, $who, unforgot $old{fact} $old{verb} $old{tidbit}."
                );
            } else {
                &say( $chl => "Sorry, $who, that's an invalid undo structure."
                      . "  Tell Zigdon, please." );
            }

        } elsif ( $undo->[0] eq 'edit' ) {
            if ( $undo->[2] and ref $undo->[2] eq 'ARRAY' ) {
                foreach my $entry ( @{ $undo->[2] } ) {
                    if ( $entry->[0] eq 'update' ) {
                        $_[KERNEL]->post(
                            db  => "DO",
                            SQL => 'update bucket_facts
                                            set verb=?, tidbit=? where id=? limit 1',
                            PLACEHOLDERS =>
                              [ $entry->[2], $entry->[3], $entry->[1] ],
                            EVENT => "db_success",
                        );
                    } elsif ( $entry->[0] eq 'insert' ) {
                        my %old = %{ $entry->[1] };
                        $old{RE}        = 0 unless $old{RE};
                        $old{protected} = 0 unless $old{protected};
                        $_[KERNEL]->post(
                            db  => "DO",
                            SQL => 'insert bucket_facts 
                                    (fact, verb, tidbit, protected, RE, mood, chance)
                                    values(?, ?, ?, ?, ?, ?, ?)',
                            PLACEHOLDERS => [
                                @old{
                                    qw/fact verb tidbit protected RE mood chance/
                                  }
                            ],
                            EVENT => "db_success",
                        );
                    }
                }
                Report "$who called undo: undone $undo->[3].";
                &say( $chl => "Okay, $who, undone $undo->[3]." );
            } else {
                &say( $chl => "Sorry, $who, that's an invalid undo structure."
                      . "  Tell Zigdon, please." );
            }
            delete $undo{$uchannel};
        } else {
            &say( $chl => "Sorry, $who, can't undo $undo->[0] yet" );
        }
    } elsif ( $addressed and $operator and $msg =~ /^alias (.*) => (.*)/ ) {
        my ( $src, $dst ) = ( $1, $2 );
        $stats{alias}++;

        $_[KERNEL]->post(
            db  => 'SINGLE',
            SQL => 'select id, verb, tidbit 
                    from bucket_facts where fact = ? limit 1',
            PLACEHOLDERS => [$src],
            BAGGAGE      => {
                cmd => "alias1",
                chl => $chl,
                src => $src,
                dst => $dst,
                who => $who,
            },
            EVENT => 'db_success'
        );
    } elsif ( $operator and $addressed and $msg =~ /^lookup (\d+)$/ ) {
        $_[KERNEL]->post(
            db  => 'SINGLE',
            SQL => 'select id, fact, verb, tidbit from bucket_facts 
                            where id = ? ',
            PLACEHOLDERS => [$1],
            BAGGAGE      => {
                cmd       => "fact",
                chl       => $chl,
                msg       => $1,
                orig      => $1,
                who       => $who,
                addressed => 0,
                editable  => 0,
                op        => 0,
                type      => $type,
            },
            EVENT => 'db_success'
        );
    } elsif ( $operator and $addressed and $msg =~ /^forget (?:that|#(\d+))$/ )
    {
        my $id = $1 || $stats{last_fact}{$chl};
        unless ($id) {
            &say( $chl => "Sorry, $who, forget what?" );
            return;
        }

        $_[KERNEL]->post(
            db  => 'SINGLE',
            SQL => 'select * from bucket_facts 
                            where id = ? ',
            PLACEHOLDERS => [$id],
            BAGGAGE      => {
                cmd => "forget",
                chl => $chl,
                who => $who,
                msg => $msg,
                id  => $id,
            },
            EVENT => 'db_success'
        );

    } elsif ( $addressed and $msg =~ /^what was that\??$/ ) {
        my $id = $stats{last_fact}{$chl};
        unless ($id) {
            &say( $chl => "Sorry, $who, I have no idea." );
            return;
        }

        if ( $id =~ /^(\d+)$/ ) {
            $_[KERNEL]->post(
                db  => 'SINGLE',
                SQL => 'select * from bucket_facts 
                                where id = ? ',
                PLACEHOLDERS => [$id],
                BAGGAGE      => {
                    cmd => "report",
                    chl => $chl,
                    who => $who,
                    msg => $msg,
                    id  => $id,
                },
                EVENT => 'db_success'
            );
        } else {
            &say( $chl => "$who: that was $id" );
        }
    } elsif ( $addressed and $msg =~ /suggest a band name/i ) {
        $_[KERNEL]->post(
            db  => 'SINGLE',
            SQL => 'select band from band_names 
                            order by rand(' . int( rand(1e6) ) . ') limit 1 ',
            BAGGAGE => {
                cmd       => "band_name_suggest",
                chl       => $chl,
                who       => $who,
                addressed => 0,
                editable  => 0,
                op        => 0,
                type      => 'irc_public',
            },
            EVENT => 'db_success'
        );
    } elsif ( $addressed and $msg eq 'something random' ) {
        &lookup(
            chl => $chl,
            who => $who,
        );
    } elsif ( $addressed and $msg eq 'stats' ) {
        unless ( $stats{stats_cached} ) {
            &say( $chl => "$who: Hold on, I'm still counting" );
            return;
        }
        my ( $awake, $units ) = &round_time( time - $stats{startup_time} );

        my $reply;
        $reply = sprintf "I've been awake since %s (about %d %s). ",
          scalar localtime( $stats{startup_time} ),
          $awake, $units;
        if ( $stats{learn} + $stats{edited} + $stats{deleted} ) {
            $reply .= "In that time, I ";
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

            # strip out the string 'factoids' from all but the first entry
            if ( @fact_stats > 1 ) {
                s/ factoids?// foreach @fact_stats[ 1 .. $#fact_stats ];
            }
            $reply .= &make_list(@fact_stats) . ". ";
        }
        $reply .= sprintf "I know now a total of %d thing%s "
          . "about %d subject%s. ",
          $stats{rows},     &s( $stats{rows} ),
          $stats{triggers}, &s( $stats{triggers} );
        $reply .= sprintf "I know of %d object%s"
          . " and am carrying %d of them. ",
          $stats{items}, &s( $stats{items} ), scalar @inventory;
        if ( $talking{$chl} == 0 ) {
            $reply .= "I'm being quiet right now. ";
        } elsif ( $talking{$chl} > 0 ) {
            $reply .= sprintf "I'm being quiet right now, "
              . "but I'll be back in about %s %s. ",
              &round_time( $talking{$chl} - time );
        }
        &say( $chl => $reply );
    } elsif ( $operator and $addressed and $msg =~ /^stat (\w+)\??/ ) {
        my $key = $1;
        if ( $key eq 'keys' ) {
            &say(   $chl => "$who: valid keys are: "
                  . &make_list( sort keys %stats )
                  . "." );
        } elsif ( exists $stats{$key} ) {
            if ( ref $stats{$key} ) {
                my $dump = Dumper( $stats{$key} );
                $dump =~ s/[\s\n]+/ /g;
                &say( $chl => "$who: $key: $dump." );
                Log $dump;
            } else {
                &say( $chl => "$who: $key: $stats{$key}." );
            }
        } else {
            &say( $chl => "Sorry, $who, I don't have statistics for '$key'." );
        }
    } elsif ( $operator and $addressed and $msg eq 'restart' ) {
        Report "Restarting at ${who}'s request";
        Log "Restarting at ${who}'s request";
        &say( $chl => "Okay, $who, I'll be right back." );
        $irc->yield( quit => "OHSHI--" );
    } elsif ( $operator and $addressed and $msg =~ /^set(?: (\w+) (.*))?/ ) {
        my ( $key, $val ) = ( $1, $2 );

        unless ( $key and exists $config_keys{$key} ) {
            &say(
                $chl => "$who: Valid keys are: " . join ", ",
                sort keys %config_keys
            );
            return;
        }

        if ( $config_keys{$key} eq 'p' and $val =~ /^(\d+)%?$/ ) {
            $config->{$key} = $1;
        } elsif ( $config_keys{$key} eq 'i' and $val =~ /^(\d+)$/ ) {
            $config->{$key} = $1;
        } elsif ( $config_keys{$key} eq 's' ) {
            $val =~ s/^\s+|\s+$//g;
            $config->{$key} = $val;
        } else {
            &say( $chl => "Sorry, $who, that's an invalid value for $key." );
            return;
        }

        &say( $chl => "Okay, $who." );
        Report "$who set '$key' to '$val'";

        &save;
        return;
    } elsif ( $operator and $addressed and $msg =~ /^get (\w+)/ ) {
        my ($key) = ($1);
        unless ( exists $config_keys{$key} ) {
            &say(
                $chl => "$who: Valid keys are: " . join ", ",
                sort keys %config_keys
            );
            return;
        }

        &say( $chl => "$key is $config->{$key}." );
    } elsif ( $addressed and $msg eq 'list vars' ) {
        unless ( keys %replacables ) {
            &say( $chl => "Sorry, $who, there are no defined variables!" );
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
    } elsif ( $addressed and $msg =~ /^list var (\w+)$/ ) {
        my $var = $1;
        unless ( exists $replacables{$var} ) {
            &say( $chl => "Sorry, $who, I don't know a variable '$var'." );
            return;
        }

        unless ( ref $replacables{$var}{vals} eq 'ARRAY'
            and @{ $replacables{$var}{vals} } )
        {
            &say( $chl => "$who: \$$var has no values defined!" );
            return;
        }

        my @vals = @{ $replacables{$var}{vals} };
        &say( $chl => "$var:", &make_list( sort @vals ) );
    } elsif ( $addressed and $msg =~ /^remove value (\w+) (.+)$/ ) {
        my ( $var, $value ) = ( lc $1, lc $2 );
        unless ( exists $replacables{$var} ) {
            &say( $chl => "Sorry, $who, I don't know of a variable '$var'." );
            return;
        }

        if ( $replacables{$var}{perms} ne "editable" and not $operator ) {
            &say( $chl =>
                  "Sorry, $who, you don't have permissions to edit '$var'." );
            return;
        }

        foreach my $i ( 0 .. @{ $replacables{$var}{vals} } - 1 ) {
            next unless lc $replacables{$var}{vals}[$i] eq $value;

            Log "found!";
            splice( @{ $replacables{$var}{vals} }, $i, 1, () );
            &say( $chl => "Okay, $who." );
            Report "$who removed a value from \$$var in $chl: $value";

            &sql(
                "delete from bucket_values where var_id=? and value=? limit 1",
                [ $replacables{$var}{id}, $value ]
            );
            return;
        }

        &say( $chl => "$who, '$value' isn't a valid value for \$$var!" );
    } elsif ( $addressed and $msg =~ /^add value (\w+) (.+)$/ ) {
        my ( $var, $value ) = ( lc $1, $2 );
        unless ( exists $replacables{$var} ) {
            &say( $chl => "Sorry, $who, I don't know of a variable '$var'." );
            return;
        }

        if ( $replacables{$var}{perms} ne "editable" and not $operator ) {
            &say( $chl =>
                  "Sorry, $who, you don't have permissions to edit '$var'." );
            return;
        }

        if ( $value =~ /\$/ ) {
            &say( $chl => "Sorry, $who, no nested values please." );
            return;
        }

        foreach my $v ( @{ $replacables{$var}{vals} } ) {
            next unless lc $v eq lc $value;

            &say( $chl => "$who, I had it that way!" );
            return;
        }

        push @{ $replacables{$var}{vals} }, $value;
        &say( $chl => "Okay, $who." );
        Report "$who added a value to \$$var in $chl: $value";

        &sql( "insert into bucket_values (var_id, value) values (?, ?)",
            [ $replacables{$var}{id}, $value ] );
    } elsif ( $operator and $addressed and $msg =~ /^create var (\w+)$/ ) {
        my $var = $1;
        if ( exists $replacables{$var} ) {
            &say( $chl =>
                  "Sorry, $who, there already exists a variable '$var'." );
            return;
        }

        $replacables{$var} =
          { vals => [], perms => "read-only", type => "var" };
        Log "$who created a new variable '$var' in $chl";
        Report "$who created a new variable '$var' in $chl";
        $undo{$chl} = [ 'newvar', $who, $var, "new variable '$var'." ];
        &say( $chl => "Okay, $who." );

        &sql( 'insert into bucket_vars (name, perms) values (?, "read-only")',
            [$var], { cmd => "create_var", var => $var } );
    } elsif ( $operator and $addressed and $msg =~ /^remove var (\w+)$/ ) {
        my $var = $1;
        unless ( exists $replacables{$var} ) {
            &say( $chl => "Sorry, $who, there isn't a variable '$var'!" );
            return;
        }

        Log Dumper $replacables{$var};
        $undo{$chl} = [
            'delvar', $who, $var, $replacables{$var},
            "deletion of variable '$var'."
        ];
        &say(
            $chl => "Okay, $who, removed variable \$$var with",
            scalar @{ $replacables{$var}{vals} }, "values."
        );
        &sql( "delete from bucket_values where var_id = ?",
            [ $replacables{$var}{id} ] );
        &sql( "delete from bucket_vars where id = ?",
            [ $replacables{$var}{id} ] );
        delete $replacables{$var};
    } elsif ( $operator
        and $addressed
        and $msg =~ /^var (\w+) type (var|verb|noun)$/ )
    {
        my ( $var, $type ) = ( $1, $2 );
        unless ( exists $replacables{$var} ) {
            &say( $chl => "Sorry, $who, there isn't a variable '$var'!" );
            return;
        }

        Log "$who set var $var type to $type";
        &say( $chl => "Okay, $who" );
        $replacables{$var}{type} = $type;
        &sql( "update bucket_vars set type=? where id = ?",
            [ $type, $replacables{$var}{id} ] );
    } elsif ( $addressed and $msg =~ /^(?:inventory|list items)[?.!]?$/i ) {
        &cached_reply( $chl, $who, "", "list items" );
    } elsif ( $addressed
        and $operator
        and $msg =~ /^do(n't)? quote ([\w\-]+)\W*$/ )
    {
        my ( $bit, $target ) = ( $1, $2 );
        if ($bit) {
            $config->{protected_quotes}{ lc $target } = 1;
        } else {
            delete $config->{protected_quotes}{ lc $target };
        }
        &say( $chl => "Okay, $who." );
        Report "$who asked to", ( $bit ? "protect" : "unprotect" ),
          "the '$target quotes' factoid.";
        &save;
    } elsif ( $addressed
        and ref $history{$chl}
        and $msg =~ /^remember ([-\w]+) ([^<>]+)$/ )
    {
        my ( $target, $re ) = ( $1, $2 );
        if ( exists $config->{protected_quotes}
            and $config->{protected_quotes}{ lc $target } )
        {
            &say( $chl =>
                  "Sorry, $who, you can't use remember for $target quotes." );
            return;
        }

        my $match;
        foreach my $line ( reverse @{ $history{$chl} } ) {
            next unless lc $line->[0] eq lc $1;
            next unless $line->[2] =~ /\Q$2/i;

            $match = $line;
            last;
        }

        unless ($match) {
            &say( $chl =>
                  "Sorry, $who, I don't remember what $target said about '$re'."
            );
            return;
        }

        my $quote;
        if ( $match->[1] eq 'irc_ctcp_action' ) {
            $quote = "* $match->[0] $match->[2]";
        } else {
            $quote = "<$match->[0]> $match->[2]";
        }
        Log "Remembering '$match->[0] quotes' '<reply>' '$quote'";
        $_[KERNEL]->post(
            db  => 'SINGLE',
            SQL => 'select id, tidbit from bucket_facts 
                    where fact = ? and verb = "<alias>"',
            PLACEHOLDERS => ["$match->[0] quotes"],
            BAGGAGE      => {
                chl       => $chl,
                msg       => "$match->[0] quotes <reply> $quote",
                orig      => "$match->[0] quotes <reply> $quote",
                who       => $who,
                addressed => 1,
                editable  => $editable,
                op        => $operator,
                type      => $type,
                fact      => "$match->[0] quotes",
                verb      => "<reply>",
                tidbit    => $quote,
                cmd       => "unalias",
                ack       => "Okay, $who, remembering \"$match->[2]\".",
            },
            EVENT => 'db_success'
        );

    } elsif (
        $addressed
        and $msg =~ /^(I|[-\w]+) \s (?:am|is) \s
                       (
                         male          |
                         female        |
                         androgynous   |
                         inanimate     |
                         full \s name  |
                         random gender
                       )\.?$/ix
        or $msg =~ / ^(I|[-\w]+) \s (am|is) \s an? \s
                       ( he | she | him | her | it )\.?$
                     /ix
      )
    {
        my ( $target, $gender, $pronoun ) = ( $1, $2, $3 );
        if ( uc $target ne "I" and lc $target ne lc $who and not $operator ) {
            &say(
                $chl => "$who, you should let $target set their own gender." );
            return;
        }

        $target = $who if $target eq 'I';

        if ($pronoun) {
            $gender = undef;
            $gender = "male" if $pronoun eq 'him' or $pronoun eq 'he';
            $gender = "female" if $pronoun eq 'her' or $pronoun eq 'she';
            $gender = "inanimate" if $pronoun eq 'it';

            unless ($gender) {
                &say( $chl => "Sorry, $who, I didn't understand that." );
                return;
            }
        }

        Log "$who set ${target}'s gender to $gender";
        $stats{users}{genders}{ lc $target } = $gender;
        &sql( "replace genders (nick, gender, stamp) values (?, ?, ?)",
            [ $target, $gender, undef ] );
        &say( $chl => "Okay, $who" );
    } elsif ( $addressed and $msg =~ /^what is my gender\??$/i ) {
        if ( exists $stats{users}{genders}{ lc $who } ) {
            &say(
                $chl => "$who: Grammatically, I refer to you as",
                $stats{users}{genders}{ lc $who } . ".  See",
                "http://wiki.xkcd.com/irc/Bucket#Docs for information on",
                "setting this."
            );

        } else {
            &load_gender($who);
            &say( $chl => "$who: I don't know how to refer to you!" );
        }
    } elsif ( $addressed and $msg =~ /^what gender is ([-\w]+)\??$/ ) {
        if ( exists $stats{users}{genders}{ lc $1 } ) {
            &say( $chl => "$who: $1 is $stats{users}{genders}{lc $1}." );
        } else {
            &load_gender($1);
            &say( $chl => "$who: I don't know how to refer to $1!" );
        }
    } else {
        my $orig = $msg;
        $msg = &trim($msg);
        if ( $addressed or length $msg >= 6 or $msg eq '...' ) {
            if ( $addressed and length $msg == 0 ) {
                $msg = "Bucket";
            }

            #Log "Looking up $msg";
            &lookup(
                chl       => $chl,
                msg       => $msg,
                orig      => $orig,
                who       => $who,
                addressed => $addressed,
                editable  => $editable,
                op        => $operator,
                type      => $type,
            );
        }
    }
}

sub db_success {
    my $res = $_[ARG0];

    print Dumper $res;
    my %bag = ref $res->{BAGGAGE} ? %{ $res->{BAGGAGE} } : {};
    if ( $res->{ERROR} ) {
        Report "DB Error: $res->{QUERY} -> $res->{ERROR}";
        Log "DB Error: $res->{QUERY} -> $res->{ERROR}";
        &error( $bag{chl}, $bag{who} ) if $bag{chl};
        return;
    }

    if ( $bag{cmd} eq 'fact' ) {
        my %line = ref $res->{RESULT} ? %{ $res->{RESULT} } : {};
        if ( defined $line{tidbit} ) {

            if ( $line{verb} eq '<alias>' ) {
                if ( $bag{aliases}{ $line{tidbit} } ) {
                    Report "Alias loop detected when '$line{fact}'"
                      . " is aliased to '$line{tidbit}'";
                    Log "Alias loop detected when '$line{fact}'"
                      . " is aliased to '$line{tidbit}'";
                    &error( $bag{chl}, $bag{who} );
                    return;
                }
                $bag{aliases}{ $line{tidbit} } = 1;
                $bag{alias_id} = $line{id} unless $bag{alias_id};

                Log "Following alias '$line{fact}' -> '$line{tidbit}'";
                &lookup( %bag, msg => $line{tidbit} );
                return;
            }

            $bag{msg}  = $line{fact} unless defined $bag{msg};
            $bag{orig} = $line{fact} unless defined $bag{orig};

            $stats{last_fact}{ $bag{chl} } = $bag{alias_id} || $line{id};
            $stats{lookup}++;

         # if we're just idle chatting, replace any $who reference with $someone
            if ( $bag{idle} ) {
                $line{tidbit} =~ s/\$who/\$someone/gi;
            }

            $line{tidbit} =
              &expand( $bag{who}, $bag{chl}, $line{tidbit}, $bag{editable} );
            return unless $line{tidbit};

            if ( $line{verb} eq '<reply>' ) {
                &say( $bag{chl} => $line{tidbit} );
            } elsif ( $line{verb} eq '\'s' ) {
                &say( $bag{chl} => "$bag{msg}'s $line{tidbit}" );
            } elsif ( $line{verb} eq '<action>' ) {
                &do( $bag{chl} => $line{tidbit} );
            } else {
                if ( lc $bag{msg} eq 'bucket' and lc $line{verb} eq 'is' ) {
                    $bag{msg}   = 'I';
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
            and (  $bag{orig} =~ /(.*?) (?:is ?|are ?)(<\w+>)\s*(.*)/i
                or $bag{orig} =~ /(.*?)\s+(<\w+(?:'t)?>)\s*(.*)/i
                or $bag{orig} =~ /(.*?)(<'s>)\s+(.*)/i
                or $bag{orig} =~ /(.*?)\s+(is(?: also)?|are)\s+(.*)/i )
          )
        {
            my ( $fact, $verb, $tidbit ) = ( $1, $2, $3 );

            if ( not $bag{addressed} and $fact =~ /^[^a-zA-Z]*<.?\S+>/ ) {
                Log "Not learning from what seems to be an IRC quote: $fact";

                # don't learn from IRC quotes
                return;
            }

            if ( $tidbit =~ m#=~\s*s/#i ) {
                Log "Not learning what looks like a botched s/// query";
                &say( $bag{chl} => "$bag{who}: Fix your s/// command." );
                return;
            }

            if ( $fact eq 'you' and $verb eq 'are' ) {
                $fact = "Bucket";
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
            } elsif ( $verb =~ /^</ and $verb =~ />$/ ) {
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

            if (    $config->{your_mom_is}
                and not $bag{op}
                and $verb eq 'is'
                and rand(100) < $config->{your_mom_is} )
            {
                $tidbit =~ s/\W+$//;
                &say( $bag{chl} => "$bag{who}: Your mom is $tidbit!" );
                return;
            }

            if ( lc $fact eq lc $bag{who} ) {
                Log "Not allowing $bag{who} to edit his own factoid";
                &say( $bag{chl} =>
                      "Please don't edit your own factoid, $bag{who}." );
                return;
            }

            Log "Learning '$fact' '$verb' '$tidbit'";
            $_[KERNEL]->post(
                db  => 'SINGLE',
                SQL => 'select id, tidbit from bucket_facts 
                        where fact = ? and verb = "<alias>"',
                PLACEHOLDERS => [$fact],
                BAGGAGE      => {
                    %bag,
                    fact   => $fact,
                    verb   => $verb,
                    tidbit => $tidbit,
                    cmd    => "unalias",
                },
                EVENT => 'db_success'
            );

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
        } elsif ( $bag{orig} =~ s/(\w+)-ass (\w+)/$1 ass-$2/ ) {
            $stats{ass}++;
            &say( $bag{chl} => $bag{orig} );
        } elsif ( $bag{orig} =~ s/\bthe fucking\b/fucking the/ ) {
            $stats{fucking}++;
            &say( $bag{chl} => $bag{orig} );
        } elsif (
            $bag{orig} !~ /extra|except/
            and rand(100) < $config->{ex_to_sex}
            and (  $bag{orig} =~ s/\ban ex/a sex/
                or $bag{orig} =~ s/\bex/sex/ )
          )
        {
            $stats{sex}++;
            &say( $bag{chl} => $bag{orig} );
        } elsif (
            $bag{orig} !~ /\?\s*$/
            and $bag{orig} =~ /^(?:
                               puts \s (.+) \s in \s (the \s)? $nick\b
                             | (?:gives|hands) \s $nick \s (.+)
                             | (?:gives|hands) \s (.+) \s to $nick\b
                            )/ix
            or (
                    $bag{addressed}
                and $bag{orig} =~ /^(?:
                                 take \s this \s (.+)
                               | have \s (an? \s .+)
                              )/x
            )
          )
        {
            my $item = ( $1 || $2 || $3 );
            $item =~ s/\b(?:his|her)\b/$bag{who}\'s/;
            $item =~ s/[ .?!]+$//;
            $item =~ s/\$([a-zA-Z])/$1/g;

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
            if (    $config->{band_name}
                and $bag{type} eq 'irc_public'
                and rand(100) < $config->{band_name} )
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
                        $_[KERNEL]->post(
                            db  => 'SINGLE',
                            SQL => 'select id from band_names where band = ?',
                            PLACEHOLDERS => [$stripped_name],
                            BAGGAGE      => {
                                %bag,
                                name          => $name,
                                stripped_name => $stripped_name,
                                words         => \@words,
                                cmd           => "band_name",
                            },
                            EVENT => 'db_success'
                        );
                    }
                }
            }
        }
    } elsif ( $bag{cmd} eq 'create_var' ) {
        if ( $res->{INSERTID} ) {
            $replacables{ $bag{var} }{id} = $res->{INSERTID};
            Log "ID for $bag{var}: $res->{INSERTID}";
        } else {
            Log "ERR: create_var called without an INSERTID!";
        }
    } elsif ( $bag{cmd} eq 'load_gender' ) {
        my %line = ref $res->{RESULT} ? %{ $res->{RESULT} } : {};
        $stats{users}{genders}{ lc $bag{nick} } = $line{gender}
          || "androgynous";
    } elsif ( $bag{cmd} eq 'load_vars' ) {
        my @lines = ref $res->{RESULT} ? @{ $res->{RESULT} } : [];

        Log "Loading replacables";
        foreach my $line (@lines) {
            unless ( exists $replacables{ $line->{name} } ) {
                $replacables{ $line->{name} } = {
                    vals  => [],
                    perms => $line->{perms},
                    id    => $line->{id},
                    type  => $line->{type}
                };
            }

            push @{ $replacables{ $line->{name} }{vals} }, $line->{value};
        }

        Log "Loaded vars:",
          &make_list(
            map { "$_ (" . scalar @{ $replacables{$_}{vals} } . ")" }
              sort keys %replacables
          );
    } elsif ( $bag{cmd} eq 'band_name' ) {
        my %line = ref $res->{RESULT} ? %{ $res->{RESULT} } : {};
        unless ( $line{id} ) {
            my @words = sort { length $b <=> length $a } @{ $bag{words} };
            $_[KERNEL]->post(
                db  => 'SINGLE',
                SQL => 'select id from `mainlog` where 
                            instr( msg, ? ) >0 and 
                            instr( msg, ? ) >0 and 
                            instr( msg, ? ) >0
                            limit 1',
                PLACEHOLDERS => \@words,
                BAGGAGE      => { %bag, cmd => "band_name2", },
                EVENT        => 'db_success'
            );
        }
    } elsif ( $bag{cmd} eq 'band_name2' ) {
        my %line = ref $res->{RESULT} ? %{ $res->{RESULT} } : {};
        unless ( $line{id} ) {
            &sql(
                'insert band_names (band) values (?)',
                [ $bag{stripped_name} ],
                { %bag, cmd => "new band name" }
            );

            $bag{name} =~ s/(^| )(\w)/$1\u$2/g;
            Report
              "Learned a new band name from $bag{who} in $bag{chl}: $bag{name}";
            &cached_reply( $bag{chl}, $bag{who}, $bag{name},
                "band name reply" );
        }
    } elsif ( $bag{cmd} eq 'band_name_suggest' ) {
        my %line = ref $res->{RESULT} ? %{ $res->{RESULT} } : {};

        &say( $bag{chl} => "How about '$line{band}'?" );
    } elsif ( $bag{cmd} eq 'edit' ) {
        my @lines = ref $res->{RESULT} ? @{ $res->{RESULT} } : [];

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
        $gflag = $bag{op} and $bag{flag} =~ s/g//g;
        $iflag = ( $bag{flag} =~ s/i//g ? "i" : "" );
        my $count = 0;
        $undo{ $bag{chl} } =
          [ 'edit', $bag{who}, [], "$bag{fact} =~ s/$bag{old}/$bag{new}/" ];

        foreach my $line (@lines) {
            $bag{old} =~ s{\\/}{/}g;
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
                $stats{edited}++;
                Report "$bag{who} edited $bag{fact}($line->{id})"
                  . " in $bag{chl}: New values: $fact";
                Log
                  "$bag{who} edited $bag{fact}($line->{id}): New values: $fact";
                my ( $verb, $tidbit );
                if ( $fact =~ /^<(\w+)>\s*(.*)/ ) {
                    ( $verb, $tidbit ) = ( "<$1>", $2 );
                } else {
                    ( $verb, $tidbit ) = split ' ', $fact, 2;
                }
                $_[KERNEL]->post(
                    db  => "DO",
                    SQL => 'update bucket_facts set verb=?, tidbit=?
                            where id=? limit 1',
                    PLACEHOLDERS => [ $verb, $tidbit, $line->{id} ],
                    EVENT        => "db_success",
                );
                push @{ $undo{ $bag{chl} }[2] },
                  [ 'update', $line->{id}, $line->{verb}, $line->{tidbit} ];
            } elsif ( $bag{op} ) {
                $stats{deleted}++;
                Report "$bag{who} deleted $bag{fact}($line->{id})"
                  . " in $bag{chl}: $line->{verb} $line->{tidbit}";
                Log "$bag{who} deleted $bag{fact}($line->{id}):"
                  . " $line->{verb} $line->{tidbit}";
                $_[KERNEL]->post(
                    db  => "DO",
                    SQL => 'delete from bucket_facts where id=? limit 1',
                    PLACEHOLDERS => [ $line->{id} ],
                    EVENT        => "db_success",
                );
                push @{ $undo{ $bag{chl} }[2] }, [ 'insert', {%$line} ];
            } else {
                &error( $bag{chl}, $bag{who} );
                Log "$bag{who}: $bag{fact} =~ s/// failed";
            }

            if ($gflag) {
                next;
            }
            &say( $bag{chl} => "Okay, $bag{who}, factoid updated." );

            if ( exists $fcache{ lc $bag{fact} } ) {
                Log "Updating cache for '$bag{fact}'";
                &cache( $_[KERNEL], $bag{fact} );
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

            if ( exists $fcache{ lc $bag{fact} } ) {
                Log "Updating cache for '$bag{fact}'";
                &cache( $_[KERNEL], $bag{fact} );
            }
            return;
        }

        &error( $bag{chl}, $bag{who} );
        Log "$bag{who}: $bag{fact} =~ s/// failed";
    } elsif ( $bag{cmd} eq 'forget' ) {
        my %line = ref $res->{RESULT} ? %{ $res->{RESULT} } : {};
        unless ( keys %line ) {
            &error( $bag{chl}, $bag{who} );
            Log "Nothing to forget in '$bag{id}'";
            return;
        }

        $undo{ $bag{chl} } = [ 'insert', $bag{who}, \%line ];
        Report "$bag{who} called forget to delete "
          . "'$line{fact}', '$line{verb}', '$line{tidbit}'";
        Log "forgetting $bag{fact}";
        $_[KERNEL]->post(
            db           => "DO",
            SQL          => 'delete from bucket_facts where id=?',
            PLACEHOLDERS => [ $line{id} ],
            EVENT        => "db_success",
        );
        &say(
            $bag{chl} => "Okay, $bag{who}, forgot that",
            "$line{fact} $line{verb} $line{tidbit}"
        );
    } elsif ( $bag{cmd} eq 'delete_id' ) {
        my %line = ref $res->{RESULT} ? %{ $res->{RESULT} } : {};
        unless ( $line{fact} ) {
            &error( $bag{chl}, $bag{who} );
            Log "Nothing found in id $bag{fact}";
            return;
        }

        $undo{ $bag{chl} } = [ 'insert', $bag{who}, \%line, $bag{fact} ];
        Report "$bag{who} deleted '$line{fact}' (#$bag{fact}) in $bag{chl}";
        Log "deleting $bag{fact}";
        &sql( 'delete from bucket_facts where id=?', [ $bag{fact} ], );
        &say( $bag{chl} => "Okay, $bag{who}, deleted "
              . "'$line{fact} $line{verb} $line{tidbit}'." );
    } elsif ( $bag{cmd} eq 'delete' ) {
        my @lines = ref $res->{RESULT} ? @{ $res->{RESULT} } : ();
        unless (@lines) {
            &error( $bag{chl}, $bag{who} );
            Log "Nothing to delete in '$bag{fact}'";
            return;
        }

        $undo{ $bag{chl} } = [ 'insert', $bag{who}, \@lines, $bag{fact} ];
        Report "$bag{who} deleted '$bag{fact}' in $bag{chl}";
        Log "deleting $bag{fact}";
        $_[KERNEL]->post(
            db           => "DO",
            SQL          => 'delete from bucket_facts where fact=?',
            PLACEHOLDERS => [ $bag{fact} ],
            EVENT        => "db_success",
        );
        my $s = "";
        $s = "s" unless @lines == 1;
        &say(   $bag{chl} => "Okay, $bag{who}, "
              . scalar @lines
              . " factoid$s deleted." );
    } elsif ( $bag{cmd} eq 'unalias' ) {
        my %line = ref $res->{RESULT} ? %{ $res->{RESULT} } : {};
        my $fact = $bag{fact};
        if ( $line{id} ) {
            Log "Dealiased $fact => $line{tidbit}";
            $fact = $line{tidbit};
        }

        $_[KERNEL]->post(
            db  => 'SINGLE',
            SQL => 'select id from bucket_facts where fact = ? and tidbit = ?',
            PLACEHOLDERS => [ $fact, $bag{tidbit} ],
            BAGGAGE      => {
                %bag,
                fact => $fact,
                cmd  => "learn1",
            },
            EVENT => 'db_success'
        );
    } elsif ( $bag{cmd} eq 'learn1' ) {
        my %line = ref $res->{RESULT} ? %{ $res->{RESULT} } : {};
        if ( $line{id} ) {
            &say( $bag{chl} => "$bag{who}: I already had it that way" );
            return;
        }

        $_[KERNEL]->post(
            db           => 'SINGLE',
            SQL          => 'select protected from bucket_facts where fact = ?',
            PLACEHOLDERS => [ $bag{fact} ],
            BAGGAGE      => { %bag, cmd => "learn2", },
            EVENT        => 'db_success'
        );
    } elsif ( $bag{cmd} eq 'learn2' ) {
        my %line = ref $res->{RESULT} ? %{ $res->{RESULT} } : {};
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

        # we said 'is also' but we didn't get any existing results
        if ( $bag{also} and $res->{RESULT} ) {
            delete $bag{also};
        }

        Report "$bag{who} taught in $bag{chl}:"
          . " '$bag{fact}', '$bag{verb}', '$bag{tidbit}'";
        Log "$bag{who} taught '$bag{fact}', '$bag{verb}', '$bag{tidbit}'";
        &sql(
            'insert bucket_facts (fact, verb, tidbit, protected)
                     values (?, ?, ?, ?)',
            [ $bag{fact}, $bag{verb}, $bag{tidbit}, $line{protected} || 0 ],
            { %bag, cmd => "learn3" }
        );
    } elsif ( $bag{cmd} eq 'learn3' ) {
        if ( $res->{INSERTID} ) {
            $undo{ $bag{chl} } = [
                'delete',         $bag{who},
                $res->{INSERTID}, "that '$bag{fact}' is '$bag{tidbit}'"
            ];

            $stats{last_fact}{ $bag{chl} } = $res->{INSERTID};
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

        if ( exists $fcache{ lc $bag{fact} } ) {
            Log "Updating cache for '$bag{fact}'";
            &cache( $_[KERNEL], $bag{fact} );
        }
    } elsif ( $bag{cmd} eq 'alias1' ) {
        my %line = ref $res->{RESULT} ? %{ $res->{RESULT} } : {};
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
            { %bag, fact => $bag{src}, tidbit => $bag{dst}, cmd => "learn3" }
        );
    } elsif ( $bag{cmd} eq 'cache' ) {
        my @lines = ref $res->{RESULT} ? @{ $res->{RESULT} } : [];
        $fcache{ lc $bag{key} } = [];
        foreach my $line (@lines) {
            $fcache{ lc $bag{key} } = [@lines];
        }
        Log "Cached " . scalar(@lines) . " factoids for $bag{key}";
    } elsif ( $bag{cmd} eq 'report' ) {
        my %line = ref $res->{RESULT} ? %{ $res->{RESULT} } : {};

        if ( $line{id} ) {
            &say( $bag{chl} => "$bag{who}: That was '$line{fact}' "
                  . "(#$bag{id}): $line{verb} $line{tidbit}" );
        } else {
            &say( $bag{chl} => "$bag{who}: No idea!" );
        }
    } elsif ( $bag{cmd} eq 'literal' ) {
        my @lines = ref $res->{RESULT} ? @{ $res->{RESULT} } : [];

        unless (@lines) {
            &error( $bag{chl}, $bag{who}, "$bag{who}: " );
            return;
        }

        if ( $bag{page} > 10 ) {
            $bag{page} = "*";
        }

        if (    $bag{page} eq '*'
            and $config->{www_url}
            and $config->{www_root}
            and -w $config->{www_root} )
        {
            my $url = "$config->{www_url}/literal_$bag{fact}.txt";
            $url =~ s/ /%20/g;
            Report
              "$bag{who} asked in $bag{chl} to dump out $bag{fact} -> $url";
            if (
                open( DUMP, ">", $config->{www_root} . "/literal_$bag{fact}.txt"
                )
              )
            {
                while ( my $fact = shift @lines ) {
                    if ( $bag{op} ) {
                        print DUMP "#$fact->{id}\t";
                    }

                    print DUMP join "\t", $fact->{verb}, $fact->{tidbit};
                    print DUMP "\n";
                }
                close DUMP;
                &say( $bag{chl} => "$bag{who}: Here's the full list: $url" );
                return;
            } else {
                Log "Failed to write dump file: $!";
                &error( $bag{chl}, $bag{who} );
                return;
            }
        }

        $bag{page} = 1 if $bag{page} eq '*';

        my $prefix = "$bag{fact}";
        if ( $lines[0]->{protected} ) {
            $prefix .= " (protected)";
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
          ref $res->{RESULT} ? map { $_->{what} } @{ $res->{RESULT} } : [];
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
    } else {
        Log "DB returned.",
          "Query: $res->{QUERY}, Result: $res->{RESULT}, Bags: $res->{BAGGAGE}";
    }
}

sub irc_start {
    Log "DB Connect...";
    $_[KERNEL]->post(
        db       => 'CONNECT',
        DSN      => $config->{db_dsn},
        USERNAME => $config->{db_username},
        PASSWORD => $config->{db_password},
        EVENT    => 'db_success',
    );

    $irc->yield( register => 'all' );
    $_[HEAP]->{connector} = POE::Component::IRC::Plugin::Connector->new();
    $irc->plugin_add( Connector => $_[HEAP]->{connector} );

    # load the variables
    $_[KERNEL]->post(
        db  => 'MULTIPLE',
        SQL => 'select vars.id id, name, perms, type, value 
                from bucket_vars vars 
                     left join bucket_values vals 
                     on vars.id = vals.var_id  
                order by vars.id',
        BAGGAGE => { cmd => "load_vars", },
        EVENT   => 'db_success'
    );

    &cache( $_[KERNEL], "Don't know" );
    &cache( $_[KERNEL], "takes item" );
    &cache( $_[KERNEL], "drops item" );
    &cache( $_[KERNEL], "pickup full" );
    &cache( $_[KERNEL], "list items" );
    &cache( $_[KERNEL], "duplicate item" );
    &cache( $_[KERNEL], "band name reply" );
    &random_item_cache( $_[KERNEL] );
    $stats{preloaded_items} = $config->{inventory_preload} || 0;

    $irc->yield(
        connect => {
            Nick     => $nick,
            Username => $config->{username} || "bucket",
            Ircname  => $config->{irc_name} || "YABI",
            Server   => $config->{server} || "irc.foonetic.net",
            Flood    => 0,
        }
    );

    $_[KERNEL]->delay( check_idle => 60 );

    if ( -f $config->{bucketlog} and open BLOG, $config->{bucketlog} ) {
        seek BLOG, 0, SEEK_END;
    }
}

sub irc_on_notice {
    my ($who) = split /!/, $_[ARG0];
    my $msg = $_[ARG2];

    Log("Notice from $who: $msg");
    if (    $who eq 'NickServ'
        and $msg =~ /Password accepted|isn't registered/ )
    {
        $irc->yield( mode => $nick => "+B" );
        unless ( $config->{hide_hostmask} ) {
            $irc->yield( mode => $nick => "-x" );
        }

        $irc->yield( join => $channel );
    }
}

sub irc_on_nick {
    my ($who) = split /!/, $_[ARG0];
    my $newnick = $_[ARG1];

    return unless exists $stats{users}{genders}{ lc $who };
    $stats{users}{genders}{ lc $newnick } =
      delete $stats{users}{genders}{ lc $who };
    &sql( "update genders set nick=? where nick=? limit 1",
        [ $newnick, $who ] );
    &load_gender($newnick);
}

sub irc_on_jointopic {
    my ( $chl, $topic ) = @{ $_[ARG2] }[ 0, 1 ];
    $topic =~ s/ ARRAY\(0x\w+\)$//;

    Log "Topic in $chl: '$topic'";
    $stats{topics}{$chl}{old} = $topic;
}

sub irc_on_join {
    my ($who) = split /!/, $_[ARG0];

    return if exists $stats{users}{genders}{ lc $who };

    &load_gender($who);
}

sub irc_on_chan_sync {
    my $chl = $_[ARG0];
    Log "Sync done for $chl";

    if ( not DEBUG and $chl eq $channel ) {
        Log("Autojoining channels");
        foreach my $chl ( $config->{logchannel}, keys %{ $config->{autojoin} } )
        {
            $irc->yield( join => $chl );
            Log("... $chl");
        }
    }
}

sub irc_on_connect {
    Log("Connected...");
    Log("Identifying...");
    &say( nickserv => "identify $pass" );
    Log("Done.");
}

sub irc_on_disconnect {
    Log("Disconnected...");
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
    my $line = $fcache{$type}[ rand( @{ $fcache{$type} } ) ];
    Log "cached '$type' reply: $line->{verb} $line->{tidbit}";

    my $tidbit = $line->{tidbit};

    if ( $type eq 'band name reply' ) {
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

    $tidbit = &expand( $who, $chl, $tidbit, 0 );
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
    $kernel->post(
        db           => 'MULTIPLE',
        BAGGAGE      => { cmd => "cache", key => $key },
        SQL          => 'select verb, tidbit from bucket_facts where fact = ?',
        PLACEHOLDERS => [$key],
        EVENT        => 'db_success'
    );
}

sub get_stats {
    my ($kernel) = @_;

    Log "Updating stats";
    $kernel->post(
        db      => 'SINGLE',
        BAGGAGE => { cmd => "stats1" },
        SQL     => "select count(distinct fact) c from bucket_facts",
        EVENT   => 'db_success'
    );
    $kernel->post(
        db      => 'SINGLE',
        BAGGAGE => { cmd => "stats2" },
        SQL     => "select count(id) c from bucket_facts",
        EVENT   => 'db_success'
    );
    $kernel->post(
        db      => 'SINGLE',
        BAGGAGE => { cmd => "stats3" },
        SQL     => "select count(id) c from bucket_items",
        EVENT   => 'db_success'
    );

    $stats{last_updated} = time;
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

sub check_idle {
    $_[KERNEL]->delay( check_idle => 60 );

    my $chl = DEBUG ? $channel : $mainchannel;
    return if time - $last_activity{$chl} < 60 * $config->{random_wait};

    return if $stats{last_idle_time}{$chl} > $last_activity{$chl};

    $stats{last_idle_time}{$chl} = time;

    my @sources = qw/MLIA SMDS IMMD factoid/;
    my $source = $config->{idle_source} || "factoid";
    if ( $source eq 'random' ) {
        $source = $sources[ rand @sources ];
    }

    $stats{chatter_source}{$source}++;

    if ( $source eq 'MLIA' or $source eq 'IMMD' ) {
        Log "Looking up $source story";
        my ( $story, $url ) =
          &read_rss( "http://feeds.feedburner.com/" . lc $source,
            qr/$source.*/, "feedburner:origLink" );
        if ($story) {
            &say( $chl => $story );
            $stats{last_fact}{$chl} = $url;
            return;
        }
    } elsif ( $source eq 'SMDS' ) {
        Log "Looking up SMDS story";
        my ( $story, $url ) =
          &read_rss( "http://twitter.com/statuses/user_timeline/62581962.rss",
            qr/^shitmydadsays: "|"$/, "link" );
        if ($story) {
            &say( $chl => $story );
            $stats{last_fact}{$chl} = $url;
            return;
        }
    }

    &lookup(
        chl  => $chl,
        who  => $nick,
        idle => 1,
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
    my @nicks =
      grep { lc $_ ne $nick and not exists $config->{exclude}{ lc $_ } }
      keys %{ $stats{users}{$channel} };
    return 'someone' unless @nicks;
    return $nicks[ rand(@nicks) ];
}

sub clear_cache {
    foreach my $channel ( keys %{ $stats{users} } ) {
        foreach my $user ( keys %{ $stats{users}{$channel} } ) {
            delete $stats{users}{$channel}{$user}
              if $stats{users}{$channel}{$user} <
                  time - $config->{user_activity_timeout};
        }
    }
}

sub random_item_cache {
    my $kernel = shift;
    my $force  = shift;
    my $limit  = $config->{random_item_cache_size} || 20;
    $limit =~ s/\D//g;

    if ( not $force and @random_items >= $limit ) {
        return;
    }

    $kernel->post(
        db      => 'MULTIPLE',
        BAGGAGE => { cmd => "itemcache" },
        SQL =>
          "select what, user from bucket_items order by rand() limit $limit",
        EVENT => 'db_success'
    );
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
        if (   ( $crafted and @inventory >= 2 * $config->{inventory_size} )
            or ( not $crafted and @inventory >= $config->{inventory_size} ) )
        {

            my $dropping_rate = $config->{item_drop_rate} || 3;
            my @drop;
            while ( @inventory >= $config->{inventory_size}
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

    return "" unless @list;
    return $list[0] if @list == 1;
    return join " and ", @list if @list == 2;
    my $last = $list[-1];
    return join( ", ", @list[ 0 .. $#list - 1 ] ) . ", and $last";
}

sub s {
    return $_[0] == 1 ? "" : "s";
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

    push @{ $history{$chl} }, [ $nick, 'irc_public', $text ];
    $irc->yield( privmsg => $chl => $text );
}

sub do {
    my $chl    = shift;
    my $action = "@_";

    push @{ $history{$chl} }, [ $nick, 'irc_ctcp_action', $action ];
    $irc->yield( ctcp => $chl => "ACTION $action" );
}

sub load_gender {
    my $who = shift;

    Log "Looking up ${who}'s gender...";
    POE::Kernel->post(
        db           => 'SINGLE',
        SQL          => 'select gender from genders where nick = ? limit 1',
        PLACEHOLDERS => [$who],
        EVENT        => 'db_success',
        BAGGAGE      => { cmd => 'load_gender', nick => $who },
    );
}

sub lookup {
    my %params = @_;
    my $sql;
    my $type;

    if ( exists $params{msg} ) {
        $sql  = "fact = ?";
        $type = "single";
    } elsif ( exists $params{msgs} ) {
        $sql = "fact in (" . join( ", ", map { "?" } @{ $params{msgs} } ) . ")";
        $params{msg} = $params{msgs}[0];
        $type = "multiple";
    } else {
        $sql  = "1";
        $type = "none";
    }

    if ( exists $params{search} ) {
        $sql .= " and tidbit like \"%$params{search}%\"";
    }

    POE::Kernel->post(
        db  => 'SINGLE',
        SQL => "select id, fact, verb, tidbit from bucket_facts 
			where $sql order by rand("
          . int( rand(1e6) ) 
          . ') limit 1',
        PLACEHOLDERS => $type eq 'multiple' ? $params{msgs}
        : $type eq 'single' ? [ $params{msg} ]
        : [],
        BAGGAGE => {
            cmd       => "fact",
            chl       => $params{chl},
            msg       => $params{msg},
            orig      => $params{orig} || $params{msg},
            who       => $params{who},
            addressed => $params{addressed} || 0,
            editable  => $params{editable} || 0,
            op        => $params{op} || 0,
            idle      => $params{idle} || 0,
            type      => $params{type} || "irc_public",
        },
        EVENT => 'db_success'
    );
}

sub sql {
    my ( $sql, $placeholders, $baggage ) = @_;

    POE::Kernel->post(
        db    => 'DO',
        SQL   => $sql,
        EVENT => 'db_success',
        $placeholders ? ( PLACEHOLDERS => $placeholders ) : (),
        $baggage      ? ( BAGGAGE      => $baggage )      : (),
    );
}

sub expand {
    my ( $who, $chl, $msg, $editable ) = @_;

    my $gender = $stats{users}{genders}{ lc $who };
    my $target = $who;
    if ( $msg =~ /\$who/ ) {
        $msg =~ s/\$who/$who/gi;
    }

    if ( $msg =~ /\$someone/i ) {
        while ( $msg =~ /\$someone/i ) {
            my $rnick = &someone($chl);
            $msg =~ s/\$someone/$rnick/i;

            $gender = $stats{users}{genders}{ lc $rnick };
            $target = $rnick;
        }
    }

    while ( $msg =~ /\$(give)?item/i ) {
        if (@inventory) {
            my $give = $editable && $1;
            my $item = &get_item($give);
            $msg =~ s/\$$1item/$item/i;
        } else {
            $msg =~ s/\$$1item/bananas/i;
        }
    }

    while ( $msg =~ /\$newitem/i ) {
        if ($editable) {
            my $newitem = shift @random_items || 'bananas';
            my ( $rc, @dropped ) = &put_item( $newitem, 1 );
            if ( $rc == 2 ) {
                &cached_reply( $chl, $who, \@dropped, "drops item" );
                return;
            }

            $msg =~ s/\$newitem/$newitem/i;
        } else {
            $msg =~ s/\$newitem/bananas/ig;
        }
    }

    if ($gender) {
        foreach my $gvar ( keys %gender_vars ) {
            next unless $msg =~ /\$$gvar\b/i;

            Log "Replacing gvar $gvar...";
            if ( exists $gender_vars{$gvar}{$gender} ) {
                my $g_v = $gender_vars{$gvar}{$gender};
                Log " => $g_v";
                if ( $g_v =~ /%N/ ) {
                    $g_v =~ s/%N/$target/;
                    Log " => $g_v";
                }
                $msg =~ s/\$$gvar\b/$g_v/gi;
            }
        }
    }

    my $oldmsg = "";
    while ( $oldmsg ne $msg and $msg =~ /\$([a-zA-Z_]\w+)/ ) {
        $oldmsg = $msg;
        my $var = $1;
        Log "Found variable \$$var";

        # yay for special cases!
        my $conjugate;
        my $record = $replacables{ lc $var };
        my $full   = $var;
        if ( not $record and $var =~ s/ed$// ) {
            $record = $replacables{$var};
            if ( $record and $record->{type} eq 'verb' ) {
                $conjugate = \&past;
                Log "Special case *ed";
            } else {
                undef $record;
                $var = $full;
            }
        }

        if ( not $record and $var =~ s/ing$// ) {
            $record = $replacables{$var};
            if ( $record and $record->{type} eq 'verb' ) {
                $conjugate = \&gerund;
                Log "Special case *ing";
            } else {
                undef $record;
                $var = $full;
            }
        }

        if ( not $record and $var =~ s/s$// ) {
            $record = $replacables{$var};
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

        if ( $record and $record->{type} eq 'noun' ) {
            Log "Special case noun";

            while ( $msg =~ /\ba \$$full\b/i ) {
                my $replacement = &set_case( $record, $var, $conjugate );
                $replacement = A($replacement);
                Log "Replacing 'a \$$full' with $replacement";
                last if $replacement =~ /\$/;

                $msg =~ s/\ba \$$full\b/$replacement/i;
            }
        }

        unless ($record) {
            Log "Can't find a record for \$$var";
            last;
        }

        Log Dumper $record;

        while ( $msg =~ /\$$full\b/i ) {
            my $replacement = &set_case( $record, $var, $conjugate );
            Log "Replacing \$$full with $replacement";
            last if $replacement =~ /\$/;

            $msg =~ s/\$$full\b/$replacement/i;
        }

        Log " => $msg";
    }

    return $msg;
}

sub set_case {
    my ( $record, $var, $conjugate ) = @_;

    my $case;
    if ( $var =~ /^[A-Z_]+$/ ) {
        $case = "U";
    } elsif ( $var =~ /^[A-Z][a-z_]+$/ ) {
        $case = "u";
    } else {
        $case = "l";
    }
    $var = lc $var;

    return "\$$var" unless $record->{vals};
    my @values = @{ $record->{vals} };
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

    # values that already include capitals are never modified
    if ( $value =~ /[A-Z]/ or $case eq "l" ) {
        return $value;
    } elsif ( $case eq 'U' ) {
        return uc $value;
    } elsif ( $case eq 'u' ) {
        return join " ", map { ucfirst } split ' ', $value;
    }
}

sub read_rss {
    my ( $url, $re, $tag ) = @_;

    require LWP::Simple;
    require XML::Simple;

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
                next if length $story->{description} > 400;
                next if $story->{description} =~ /\[\.\.\.\]/;

                return ( $story->{description}, $story->{$tag} );
            }
        }
    }
}
