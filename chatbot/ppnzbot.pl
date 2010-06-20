#!/usr/bin/perl

use strict;
use warnings;

use Data::Dumper;
use Time::HiRes ();

use AnyEvent;
use AnyEvent::IRC::Client;
use AnyEvent::Feed;

my $c = AnyEvent->condvar;

my $host = 'irc.piratpartiet.se';
my $port = 6667;
my $info = {
    nick => 'kiwi',
    user => 'kiwi',
    real => 'PPNZ bot',
};

no warnings qw{qw};
my @channels = qw{
    #ppnz
    #ppnzsocial
};
use warnings qw{qw};

my $ping = sub {
    my ($self, undef, $nick) = @_;
    my $time = Time::HiRes::time();
    $self->send_srv(PRIVMSG => $nick, "\001PING $time\001");
};

# Public chat command list.  This is a hash that includes the lowecase command name (to match the first word of the msg)
# and a subref to process the command.
my $public_commands = {
    '!test' => sub {
	my ($self, $chan, $nick) = @_;
	$self->send_chan($chan, PRIVMSG => $chan, "$nick: It works!");
    },
    '!ping' => $ping,
};

# Private message command list ... same as above.
my $private_commands = {
    '!test' => sub {
	my ($self, undef, $nick) = @_;
	$self->send_srv(NOTICE => $nick, "It works!");
    },
    '!ping' => $ping,
};

my %feeds = qw{
	http://twitter.com/statuses/user_timeline/88316972.rss			Twitter
	http://www.facebook.com/feeds/page.php?format=atom10&id=305641940721	Facebook
};

foreach my $feed (values %feeds) {
    $feed = [$feed, 0];
}

my $timer;
my $con = new AnyEvent::IRC::Client;

sub read_feed {
    my ($feed_reader, $new_entries, $feed, $error) = @_;

    if (defined $error) {
	warn "ERROR: $error\n";
	return;
    }

    # Skip the first reading so we don't display a bunch of old records.
    if (!$feeds{$feed_reader->url()}[1]) {
	$feeds{$feed_reader->url()}[1] = 1;
	return;
    }

#    my $title = $feed->{rss}{channel}{title};
#    $title =~ s:\s*/\s*.*::;
    my $title = $feeds{$feed_reader->url()}[0];

    for (@$new_entries) {
	my ($hash, $entry) = @$_;
	# $hash a unique hash describing the $entry
	# $entry is the XML::Feed::Entry object of the new entries
	# since the last fetch.

	my $link = $entry->{entry}{link};
	my $etitle = $entry->{entry}{title};

	my $msg = "[$title] $etitle @ $link";
	
	foreach my $chan (@channels) {
	    $con->send_chan($chan, PRIVMSG => $chan, $msg);
	}

#	print Dumper($hash, $entry);
    }
}

foreach my $url (keys %feeds) {
    AnyEvent::Feed->new (
			 url      => $url,
			 interval => 30,
			 on_fetch => \&read_feed,
			 );
  }

$con->reg_cb (connect => sub {
    my ($con, $err) = @_;
    if (defined $err) {
	warn "connect error: $err\n";
	return;
    }
});

# Stuff to do when connected:
$con->reg_cb (registered => sub {
    print "I'm in!\n";
});

$con->reg_cb (disconnect => sub { print "I'm out!\n"; $c->broadcast });

# Register a callback for public commands
$con->reg_cb(publicmsg => sub {
    my ($self, $chan, $ircmsg) = @_;
    my $msg = $ircmsg->{params}[1];
    my ($nick) = $ircmsg->{prefix} =~ /^(.*?)!/;
    my ($cmd) = $msg =~ /^(\S*)/;
    $cmd = lc $cmd;

    return unless $public_commands->{$cmd};

    $public_commands->{$cmd}($self, $chan, $nick, $msg, $ircmsg);
});

# Register a callback for private messages
$con->reg_cb(privatemsg => sub {
    my ($self, $tonick, $ircmsg) = @_;
    my $msg = $ircmsg->{params}[1];
    my ($nick) = $ircmsg->{prefix} =~ /^(.*?)!/;
    my ($cmd) = $msg =~ /^(\S*)/;
    $cmd = lc $cmd;

    return unless $private_commands->{$cmd};

    $private_commands->{$cmd}($self, $tonick, $nick, $msg, $ircmsg);
});

# Process the ping replies
# Doesn't quite work yet, needs some debugging.
#$con->reg_cb(ctcp => sub {
#    my ($self, $src, $target, $tag, $msg, $type) = @_;
#    return unless $type eq 'NOTICE';

#    my $elapsed = Time::HiRes::time() - $msg;

#    print "CTCP src=$src tag=$tag type=$type msg=$msg";
#    $msg = sprintf('Ping time %01.2f seconds', $elapsed);
#    $self->send_srv(PRIVMSG => 
#});

# Debugging
#$con->reg_cb(debug_recieve

# Join channels:
$con->send_srv(JOIN => join ',', @channels);

$con->connect ($host, $port, $info);
$c->wait;
$con->disconnect;
