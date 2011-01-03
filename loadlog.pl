#!/usr/bin/perl -w

use strict;
use DBI;
use Time::HiRes qw/sleep/;
$|++;

my $rebuild = shift;
my $sleep = shift || 0.005;
my $db = DBI->connect("DBI:mysql:database=dbname", "username", "password") or die "no DB";

my $add      = $db->prepare("insert into mainlog (stamp, msg) values (?, ?)") or die "Can't prepare add: $!";
my $findword = $db->prepare("select id from word2id where word=?") or die "Can't prepare findword: $!";
my $addword  = $db->prepare("insert into word2id (word) values (?)") or die "Can't prepare addword: $!";
my $newest   = $db->prepare("select max(stamp) as m from mainlog") or die "Can't prepare newest: $!";
my $addline  = $db->prepare("insert ignore into word2line (word, line) values (?, ?)") or die "Can't prepare addline: $!";
my $addcount = $db->prepare("update word2id set `lines`=`lines`+1 where id = ?") or die "Can't prepare addcount: $!";

my $ts = 0;
my $date;
my $max;
my %words;

$newest->execute;
$max = $newest->fetchrow_hashref;
$max = $max->{m};
print "max timestamp: $max\n";

my %months = qw/Jan 1 Feb 2 Mar 3 Apr 4  May 5  Jun 6
                Jul 7 Aug 8 Sep 9 Oct 10 Nov 11 Dec 12/;
my %stats;

my $mainlog;
if ($rebuild) {
  print scalar localtime, " - selecting from mainlog starting at $rebuild...\n";
  $mainlog = $db->prepare("select id, msg from mainlog where id > ? limit 1000000") or die "Failed to prepare mainlog: $!";
  $mainlog->execute($rebuild);
  print scalar localtime, " - complete...\n";
}
while (1) {
  my $mainline;
  my $line_id;
  if ($rebuild) {
    $mainline = $mainlog->fetchrow_hashref;
    last unless $mainline->{id};
    $_ = $mainline->{msg};
    $line_id = $mainline->{id};
    if ($line_id % 1000 == 0) { print scalar localtime, " - $line_id\n"; }
  } else {
    $_ = <>;
    last unless defined $_;

    chomp;
    # --- Day changed Tue Aug 15 2006
    if (/^--- (?:Day changed|Log opened) (...) (...) ([ \d]\d)(?: \d\d:\d\d:\d\d)? (\d\d\d\d)$/) {
      my ($day, $mon, $mday, $year) = ($1, $2, $3, $4);
      $date = sprintf("%04d-%02d-%02d", $year, $months{$mon}, $mday);
      print "Date = $date\n";
      next;
    }

    next unless $date;

    s/^(\d\d:\d\d) // or next;
    my $time = $1;
    next unless s/^<[^>]+> //;

    #print "$date $time $_\n";
    if ($max and "$date $time" lt $max) {
      #print "skipping... $date $time\r";
      next;
    }

    if (/^(\S+):/ and $1 ne 'http') {
      s/^\S+: *//;
    }
    s/^\s+|\s+$//g;
    s/\s\s+/ /g;

    #print "$date $time\r";
    $add->execute("$date $time", $_);
    $line_id = $db->last_insert_id(undef, undef, undef, undef);
    $stats{added}++;
  } 

  s/[^\- \w']+//;
  foreach my $word (split ' ', $_) {
    $word = &trim($word);
    next unless $word;
    next if length $word >= 32 or $word =~ /^http/;
    unless (exists $words{$word}) {
      if ($findword->execute($word) > 0) {
        $words{$word} = $findword->fetchrow_hashref;
        $words{$word} = $words{$word}{id};
        $findword->finish();
      } else {
        $addword->execute($word);
        $words{$word} = $db->last_insert_id(undef, undef, undef, undef);
        $stats{words}++;
      }
    }

    $addline->execute($words{$word}, $line_id);
    $addcount->execute($words{$word});
    $stats{word2lines}++;
    sleep $sleep if $rebuild;
  }

  if (keys %words > 100000) { print scalar localtime, " - Flushing words...\n"; %words = () };
}
print "\n\n$stats{added} lines added, $stats{words} new words, $stats{word2lines} pointers.\n";

sub trim {
  my $word = shift;
  $word =~ s/[^0-9a-zA-Z'\-]//g;
  return lc $word;
}

__END__
--- Log opened Tue Aug 08 17:12:18 2006
17:12 -!- xkcd [xkcd@hide-C3A0E2D7.isomerica.net] has joined #xkcd
17:12 [Users #xkcd]
17:12 [@xkcd] 
17:12 -!- Irssi: #xkcd: Total of 1 nicks [1 ops, 0 halfops, 0 voices, 0 normal]
17:12 -!- Channel #xkcd created Tue Aug  8 17:12:16 2006
17:12 -!- Irssi: Join to #xkcd was synced in 2 secs
17:22 -!- blorpy [emad@hide-33D50916.dsl.rcsntx.swbell.net] has joined #xkcd
17:22 < blorpy> gar!
17:22 <@xkcd> FUCKER
17:22 < blorpy> where?!
17:23 <@xkcd> over there, next to the guy with tourette's
17:25 < blorpy> oh, john stossel
17:28 <@xkcd> No, the other one.
18:04 < blorpy> so do i get to be your 2nd in command
18:04 < blorpy> because i really want to haze some nerds 
18:07 -!- mode/#xkcd [+ntr] by ChanServ
18:09 <@xkcd> sure, why not
18:15 -!- davean [davean@hide-C3A0E2D7.isomerica.net] has joined #xkcd
18:57 -!- blorpy [emad@hide-33D50916.dsl.rcsntx.swbell.net] has quit [Ping timeout]
19:00 -!- blorpy [emad@87B136C.2F31D6F.E582708A.IP] has joined #xkcd
20:35 < blorpy> hi
21:28 <@xkcd> :D
21:44 -!- stu [stu@hide-8ACFF8D] has joined #xkcd
21:44 < stu> n00bs
21:45 < blorpy> st00bs
21:46 < stu> waddup blorpy
21:48 < blorpy> stu: i heard this neat song, is what
21:49 < blorpy> http://zork.net/~spork/dead_prez-hell_yeah-diplo.mp3
21:50 < stu> blorpy: heh
21:50 < stu> blorpy: yeah
21:50 < stu> i have that song
21:50 < stu> its great
21:50 < stu> great
21:51 < blorpy> yeah it rocks
21:51 < blorpy> he had a concert here a couple weeks back
21:51 < blorpy> and i didnt go
21:51 < blorpy> this diplo fellow
21:51 < blorpy> who does the mix
21:51 < stu> blorpy: http://isomerica.net/~stu/mp3/

--- Day changed Tue Aug 15 2006

