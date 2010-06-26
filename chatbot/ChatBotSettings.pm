# Settings for chat bot.

package ChatBotSettings;

# Connection settings
our $Host = 'irc.example.com';
our $Port = 6667;
our $Nick = 'chatbot';
our $Ident = 'chatbot';
our $RealName = 'ChatBot';

# NickServ Settings
our $NSpass = 'password';

# Channels to join
{
    no warnings qw{qw};
    our @Channels = qw{
	#MyChannel
	#MyOtherChannel
    };
}

# RSS Feeds to monitor (URL / Name)
our %Feeds = qw{
	http://twitter.com/statuses/user_timeline/12345678.rss			Twitter
	http://www.facebook.com/feeds/page.php?format=rss20&id=1234567890	Facebook
};

1;
