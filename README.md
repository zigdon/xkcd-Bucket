xkcd-Bucket
===========

Bucket is one of three bots in [xkcd's](http://xkcd.com) IRC Channel.
The source is available here, which includes a sample database with a minimal configuration.

The full database is not publicly available.

What is Bucket?
---------------

Bucket is a bot that can be taught factoids that will be triggered when certain phrases
are said. The full documentation is available [here](http://wiki.xkcd.com/irc/Bucket), but this
document will serve as a quick overview of some of Bucket's functionality.

Bucket must be addressed to be taught factoids, either as "Bucket:" or "Bucket," (or whatever you choose
to name your instance), most clients should do this by tab-completion. 

Installing
----------

1. Clone this repository.
2. Set up a MySQL database, other databases may work but are not guaranteed to do so.
    `$ sudo apt-get install mysql-server`
  *Replace this appropriately depending on your operating system.
3. Create the tables in bucket.sql. You may need the arguments `--user=root --password` in order for it
to work.
    ```$ mysqladmin create bucket
    $ mysql -D bucket < bucket.sql
    $ mysql -D bucket < sample.sql```
4. Create a user for Bucket, and grant all perms on the bucket database.
    `$ echo 'grant all on bucket.* to bucket identified by "s3kr1tP@ss"' | mysql`
5. Edit config file (bucket.yml)
6. Install perl modules.
    ```$ sudo cpan POE POE::Component::IRC POE::Component::SimpleDBI Lingua::EN::Conjugate Lingua::EN::Inflect 
    Lingua::EN::Syllable YAML HTML::Entities URI::Escape XML::Simple```
7. Set bucket.pl as executable.
    `$ chmod +x bucket.pl`
8. Pre-flight checklist
  1. Register your Bucket's nick with NickServ
  2. Register your Bucket's logging and config channels, and configure them as private and restricted.
  3. Add your Bucket's nick to the allow list for the logging and config channels. 
9. Start Bucket.
    `$ ./bucket.pl`
10. Start adding factoids!

What can Bucket do?
-------------------

This is only a brief overview, the full documentation is [here](http://wiki.xkcd.com/irc/Bucket).

### Factoids

#### X is Y

This is the most common and basic method of teaching Bucket factoids, it is added by simply saying `X is Y`. 
If "X" is said later, Bucket will reply with "X is Y". Be careful, though, as it is also easy to accidentally
create factoids this way. `X is also Y` will have the same effect. 

`X is Y is Z` will be split between `X` and `Y`, and Bucket will respond to the trigger "X" with "X is Y is Z."
`X is Y <is> Z` must be used for "X is Y" to trigger "X is Y is Z." See the section on <verb>s below.

#### X are Y

This is used identically to `X is Y`, with the exception being that Bucket will respond to "X" with "X are Y."

#### X \<verb\> Y

Bucket is smart enough to know verbs! `X loves Y` and similar phrases will cause X to trigger "X loves Y."

`X<'s> Y` is a special variant of this, making "X" trigger "X's Y."

#### X \<reply\> Y

Perhaps the second-most used factoids are `X <reply> Y` factoids. Saying "X" will make Bucket respond "Y."

#### X \<action\> Y

This will make Bucket use a `/me` when he replies. Thus, saying "X" will make Bucket `/me Y`.

#### Commands

Bucket is not a client! Teaching him factoids such as `Quit <reply> /quit` will not work as intended.

#### Quotes

Bucket has the ability to remember things that users have said. `Remember {nick} {snippet_from_line}` will remember
that user's line under the trigger "nick quotes."

### Searching and Editing

#### Listing

`literal X` will list all the factoids associated with that trigger, separated by `|`. If there are too many, Bucket
will automatically create a new page and append "*n* more." `literal[*p*] X` will list page number *p*.

`literal[*] X` will make Bucket produce a URL of a text file with all of the associated factoids.

`X =~ /m/` will make Bucket reply with the first factoid in trigger "X" containing "m."

"what was that?" will make Bucket list the last spoken factoid with all of its details: "That was X(#000): <reply> Y", the
number being the factoid ID.

#### Editing
`X =~ s/m/n/` will replace "m" with "n" in the trigger "X." `X =~ s/m/n/i` (adding an "i" flag) will replace case-insensitively.
If there is more than one appearance of "m" in "X," it will replace the first instance. Channel operators can add a "g" flag to 
replace all.

`undo last` undoes the last change to a factoid. Non-ops can only `undo last` if they made the last change.

#### Variables

Variables will *only* work in responses. 

`$noun` and `$nouns` will add random noun(s) where they are placed.

`$verb`, `$verbed` and `$verbing` will do similarily with verbs.

`$adjective` and `$preposition` have similar effects.

`$who` will be replaced with the person who triggered the factoid, while `$someone` will choose a (semi-)random user.

`$to` will be replaced by the intended recipient, for example, `<someuser> anotherguy: blah blah` will replace $to with "anotherguy."

Bucket also has gender variables (among other variables.) They can be found [here](http://wiki.xkcd.com/irc/Bucket#Gender).

#### Inventory

Items can be put in Bucket, given to Bucket, or items given to Bucket. Bucket is also smart enough to understand posession, and will
add "username's item" appropriately. Bucket's inventory can be listed with the command `inventory`.

Ops can delete items using `detailed inventory` and `delete item #x`.

`$item`, `$giveitem`, and `$newitem` are all variables concerning items. `$item` will use an item in Bucket's inventory, `$giveitem` will
use an item and discard it, and `$newitem` will use a random item from previously learned items.

#### Special Factoids
Bucket also has some factoids for hard-coded uses. These include "Don't Know", "Automatic Haiku" and "Band Name Reply."

#### Contacting

Any bugs, feature requests or questions should be directed to zigdon at
irc.foonetic.net.  Or, ask people in #xkcd and #bucket there - many have years
of experience with Bucket.
