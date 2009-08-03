# A usertag to restrict the tags allowed in the body text.  Converts the opening [ in any other tag
# to &#91;.
# tags          = space separated list of tags to allow.  Regexps ok, - or _ will be converted to [-_].
# unsafe=1      = convert &#91; to [ in the body text before processing.
# interpolate=1 = interpolate the body first.  This is good if you have to read data from the output
#                 of another tag and then parse that output for other specific tags.  Be certain that
#                 those tags do reparse thier output or it defeats the purpose.
# reparse=0     = don't do this or none of the tags will be parsed, not even the ones you want!

UserTag restrict-tags Description	Parse only the allowed tags in the body.
UserTag restrict-tags Order 	tags
UserTag restrict-tags AddAttr	1
UserTag restrict-tags HasEndTag	1
UserTag restrict-tags Interpolate	1
UserTag restrict-tags Routine	<<EOR
sub {
	my ($tags, $opt, $body) = @_;

	if ($opt->{unsafe}) {
		$body =~ s/&#91;/[/sg;
	}

	$tags =~ s/^\s+//;
	$tags =~ s/\s+$//;
	$tags =~ s/\s+/|/g;
	$tags =~ s/[-_]/[-_]/g;
	$body =~ s/\[(?!(?:$tags)\b)/&#91;/ig;
	return $body;
}
EOR
