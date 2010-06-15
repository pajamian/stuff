# Copyright ...
#
# $Id$

UserTag fedex-query Order	servicetype weight
UserTag fedex-query addAttr
UserTag fedex-query Version	$Revision$
UserTag fedex-query Documentation <<EOD

=head1 fedex-query

Interface to the FedEx Web Services API.

=head2 Summary

[fedex-query servicetype weight]

For a list of named attributes see the FedEx documentation

=cut

EOD

UserTag fedex-query Routine <<EOR

# ************************************************************
# SOAP::WSDL is brain dead.  The modules it generates are missing a lot of the important data that
# is available from the wsdl files that we need to make this all work.  As a workaround we will read
# in the data from the wsdl file itself with XML::Simple and get the extra data we need.

my %fedex_services;
BEGIN {
    my %service_defaults =
	(
	 lc 'Rate' => {
	     request_sub => sub {
		 my %defaults;
		 {
		     # Origin defaults come from the ADDRESS, CITY and SHIP_DEFAULT_COUNTRY variables.
		     my $address = $::Variable->{ADDRESS};
		     $address = '' unless defined $address;
		     $address = [split(/\s*[,\n]\s*/, $address)];

		     # Attempt to parse out the city, state and zip from one line when we don't know what format it will be in.
		     my $city = $::Variable->{CITY};
		     $city = '' unless defined $city;
		     $city =~ s/(\S*\d\S*)//;
		     my $zip = $1;
		     $city =~ s/\s+$//;
		     $city =~ s/,\s*(.+)// or $city =~ s/\s+(\S+)$//;
		     my $state = $1;

		     my $country = $::Variable->{SHIP_DEFAULT_COUNTRY};
		     $country = '' unless defined $country;

		     $defaults{lc 'OriginStreetLines'}		= $address;
		     $defaults{lc 'OriginCity'}			= $city;
		     $defaults{lc 'OriginPostalCode'}		= $zip;
		     $defaults{lc 'OriginStateOrProvinceCode'}	= $state;
		     $defaults{lc 'OriginCountryCode'}		= $country;
		 }

		 {
		     # Other Defaults
		     $defaults{lc 'DropoffType'}					= 'REGULAR_PICKUP';
		     $defaults{lc 'ServiceType'}					= 'FEDEX_GROUND';
		     $defaults{lc 'PackagingType'}					= 'YOUR_PACKAGING';
		     $defaults{lc 'RateRequestPackageSummaryPieceCount'}		= 1;
		     $defaults{lc 'RateRequestPackageSummaryTotalWeightUnits'}	= 'LB';
		 }
		 return \%defaults;
	     },
	     cgi_map => {
		 lc 'DestinationStreetLines'		=> '@address',
		 lc 'DestinationCity'			=> 'city',
		 lc 'DestinationStateOrProvinceCode'	=> 'state',
		 lc 'DestinationPostalCode'		=> 'zip',
		 lc 'DestinationCountryCode'		=> 'country',
		 lc 'DestinationResidential'		=> 'residential',
	     },
	     reply => 'RatedShipmentDetailsShipmentRateDetailTotalNetChargeAmount',
	 },
	 );

    eval {
	use XML::Simple;
    };
    if ($@) {
	::logError("[fedex-query]: ERROR: $@");
	last;
    }

    my %alltypes;
    my $ns; # Target namespace
    my $xs; # XMLSchema namespace

    # recursively parse out the subtypes of the passed type and return the data in one structure.
    # Also creates a map of typenames to thier elements and a list of the elements with fixed
    # attributes.
    my $parsetype = sub {};
    $parsetype = sub {
	my ($types, $typenamemap, $fixed, $path) = @_;
	$types = [@$types]; # Copy
	$typenamemap ||= {};
	$fixed ||= [];
	$path ||= [];
	my $return = {};

	# We use an old fashioned C-style for loop because we need to add to the end of the list from inside the loop.
	for (my $i = 0; $i < @$types; $i++) {
	    my %type = %{$types->[$i]};

	    # Grab the documentation
	    $return->{'documentation'} = join ("\n\n", $return->{'documentation'} || (), map { join ("\n", @{$_->{"${xs}:documentation"}}) } @{$type{"${xs}:annotation"}});

	    delete $type{"${xs}:annotation"};

	    # If this is an enumeration just return the values.
	    if (exists $type{"${xs}:restriction"}) {
		push (@{$return->{'enumeration'}}, map { map { $_->{'value'} } @{$_->{"${xs}:enumeration"}} } @{$type{"${xs}:restriction"}});
		delete $type{"${xs}:restriction"};
	    }

	    # If this is an element then we have more parsing to do...
	    if (exists $type{"${xs}:element"}) {
		while (my ($key, $value) = each %{$type{"${xs}:element"}}) {
		    my $lcname = lc $key; # lowercase name

		    my $array = $value->{'maxOccurs'};
		    $array = 1 unless defined $array;
		    $array = 2 if $array eq 'unbounded';
		    $array = $array > 1;

		    my $docs;
		    unless (ref $value->{"${xs}:annotation"}[0]{"${xs}:documentation"}[0]) {
			$docs = join ("\n\n", map { join ("\n", @{$_->{"${xs}:documentation"}}) } @{$value->{"${xs}:annotation"}});
		    }

		    my $element = {
			'name'		=> $key,
			'array'		=> $array,
			'documentation'	=> $docs,
		    };

		    my @path = @$path; # Copy and localize
		    push (@path, $element); # Reference to all the elements up to this one.
		    $element->{'path'} = \@path;

		    # Long name for this element
		    my $longname = $element->{'longname'} = join('', map { $_->{'name'} } @path);
		    $element->{'longdoc'} = join("\n", map { defined $_->{'documentation'} ? $_->{'documentation'} : () } @path);

		    $element->{'longdoc'} .= "\nThis element can be used in an array." if $array;
		    $element->{'longdoc'} .= "\nThis element is required." if !exists $value->{'minOccurs'} || $value->{'minOccurs'};

		    my $type = $value->{'type'} || $value->{"${xs}:simpleType"}[0]{"${xs}:restriction"}[0]{'base'};

		    if ($type =~ s/^\Q$ns\E://) {
			$element->{'typename'} = $type;
			my $typeref = $parsetype->([$alltypes{$type}], $typenamemap, $fixed, \@path);
			if (exists $typeref->{'enumeration'}) {
			    $element->{'enumeration'} = $typeref->{'enumeration'};
			    $element->{'longdoc'} .= "\n" . $typeref->{'documentation'} . "\nPossible values are " . join(', ', @{$typeref->{'enumeration'}}) . '.';
			} else {
			    $element->{'type'} = $typeref;
			}
		    }

		    if ($type =~ s/^\Q$xs\E:// || $element->{'enumeration'}) {
			$element->{'typename'} = $type unless $element->{'enumeration'};

			# Store it in the type name map under the short name.
			my $shortnamemap = {
			    name	=> $key,
			    element	=> $element,
			};
			if (exists $typenamemap->{$lcname}) {
			    # both names exist, so compare levels, the higher level element gets precidence.
			    my $levela = @path;
			    my $levelb = @{$typenamemap->{$lcname}{'element'}{'path'}};
			    if ($levela < $levelb) {
				$typenamemap->{$lcname} = $shortnamemap;
			    } elsif ($levela == $levelb) {
				# if they're both on the same level then the element which comes first alphabetically (after
				# lowercasing) gets precidence.
				if (lc $longname lt lc $typenamemap->{$lcname}{'element'}{'longname'}) {
				    $typenamemap->{$lcname} = $shortnamemap;
				}
			    } # Do nothing if a > b
			} else {
			    $typenamemap->{$lcname} = $shortnamemap;
			}

			# Also a long name (in case the shortened name is not unique)
			$typenamemap->{lc $longname} = {
			    name	=> $longname,
			    element	=> $element,
			};

			# Is there a fixed value for this element?
			if (exists $value->{'fixed'}) {
			    $element->{'fixed'} = $value->{'fixed'};
			    push (@$fixed, $element);
			}
		    }

		    $return->{'elements'}{$lcname} = $element;
		}
		delete $type{"${xs}:element"};
	    }

	    # If this is a sequence then simply add it to the end of the current list of types to parse.
	    if (exists $type{"${xs}:sequence"}) {
		push (@$types, @{$type{"${xs}:sequence"}});
		delete $type{"${xs}:sequence"};
	    }

	    # ...and for our purposes we can also add a choice right to the end of the types.
	    if (exists $type{"${xs}:choice"}) {
		push (@$types, @{$type{"${xs}:choice"}});
		delete $type{"${xs}:choice"};
	    }
	}
	return $return;
    };

    # Grab the path for the fedex wsdl files.  We only need this at startup and it will interfere with
    # the usertag if left in place so we delete it as well.
    my $wsdl_path = delete $Global::Variable->{'FEDEX_WSDL_PATH'};
    $wsdl_path = 'wsdl/fedex' unless defined $wsdl_path;

    # Prefix used for FedEx Modules
    my $module_prefix = delete $Global::Variable->{'FEDEX_MODULE_PREFIX'};
    $module_prefix = 'FedEx' unless defined $module_prefix;

    unless (opendir (DIR, $wsdl_path)) {
	::logError("[fedex-query]: ERROR: Can't open directory $wsdl_path: $!");
	last;
    }

    my @wsdl_files = grep { /\.wsdl$/i && -f "$wsdl_path/$_" && -r _ } readdir(DIR);
    closedir(DIR);

    # Parse the wsdl files.
    foreach (@wsdl_files) {
	my $wsdl = XMLin("$wsdl_path/$_", ForceArray => 1);

	# Parse out the namespaces we will need for elements.
	{
	    my $target = $wsdl->{'targetNamespace'};
	    while (my ($key, $value) = each %$wsdl) {
		next unless $key =~ s/^xmlns://;
		$ns = $key if $value eq $target;
		$xs = $key if $value =~ /w3\.org.+xmlschema/i;
	    }
	    foreach (@{$wsdl->{types}}) {
		while (my ($key, $value) = each %$_) {
		    next unless $key =~ /:schema$/;
		    foreach (@$value) {
			while (my ($subkey, $subval) = each %$_) {
			    next unless $subkey =~ s/^xmlns://;
			    $ns = $subkey if $subval eq $target;
			    $xs = $subkey if $subval =~ /w3\.org.+xmlschema/i;
			}
		    }
		}
	    }
	}

	my $name = [keys %{$wsdl->{'service'}}];
	$name = $name->[0];
	my $services = [values %{$wsdl->{'portType'}}];
	$services = $services->[0]{'operation'};
	my $interface;
	%alltypes = (map { map { (%{$_->{"${xs}:complexType"}||{}}, %{$_->{"${xs}:simpleType"}||{}}) } @{$_->{"${xs}:schema"}} } @{$wsdl->{'types'}});

	# Load up the generated interface module.
	eval <<EOE;
		use \Q$module_prefix\EInterfaces::\Q$name\E::\Q$name\EPort;
		\$interface = \Q$module_prefix\EInterfaces::\Q$name\E::\Q$name\EPort->new();
EOE
    	if ($@) {
	    ::logError("[fedex-query]: ERROR: $@");
	    next;
	}

	# Loop through each service available in this interface.
	while (my ($method, $ref) = each %$services) {
	    # Parse out the data for the Request structure.
	    my $request_name_map = {};
	    my $request_fixed = [];
	    my $request_name = $ref->{'input'}[0]{'message'};
	    $request_name =~ s/^\Q$ns\E://;
	    my $request = $parsetype->([$alltypes{$request_name}], $request_name_map, $request_fixed);

	    # ...and the Reply structure.
	    my $reply_name_map = {};
	    my $reply_name = $ref->{'output'}[0]{'message'};
	    $reply_name =~ s/^\Q$ns\E://;
	    my $reply = $parsetype->([$alltypes{$reply_name}], $reply_name_map);

	    my $servicename = $request_name;
	    $servicename =~ s/Request$//;
	    
	    # Record the service in the fedex_services hash.
	    $fedex_services{lc $servicename} = {
		'name'			=> $servicename,
		'interface'		=> $interface,
		'method'		=> $method,
		'request_name'		=> $request_name,
		'request'		=> $request,
		'request_name_map'	=> $request_name_map,
		'request_fixed'		=> $request_fixed,
		'reply_name'		=> $reply_name,
		'reply'			=> $reply,
		'reply_name_map'	=> $reply_name_map,
		'defaults'		=> $service_defaults{lc $servicename} || {
		    request	=> sub { {} },
		    cgi_map	=> {},
		    reply	=> '',
		},
	    };
	}
    }
}

sub {
    my $opt = pop;
    # Lowercase the args to make everything case-insensitive
    $opt = { map { ((lc) => $opt->{$_}) } keys %$opt };

    my $joiner = delete $opt->{'joiner'};
    $joiner = "\n" unless defined $joiner;
    my $hashjoiner = delete $opt->{'hashjoiner'};
    $hashjoiner = ' => ' unless defined $hashjoiner;

    my $output_list = sub {};
    $output_list = sub {
	my ($list, $oljoiner, $olhashjoiner) = @_;
	$oljoiner = $joiner unless defined $oljoiner;
	$olhashjoiner = $hashjoiner unless defined $olhashjoiner;
	if (!ref $list || $reply eq 'ref') {
	    return $list;
	} elsif (ref $list eq 'ARRAY') {
	    return join($oljoiner, @$list);
	} elsif (ref $list eq 'HASH') {
	    my @out;
	    foreach my $key (sort keys %$list) {
		my $value = $list->{$key};
		$key .= $olhashjoiner;
		if (ref $value) {
		    $key .= $output_list->($value, $olhashjoiner, $olhashjoiner);
		} else {
		    $key .= $value
		}
		push(@out, $key);
	    }
	    return join($oljoiner, @out);
	} else {
	    ::logError('[fedex-query]: WARNING: Invalid ref passed to output_list.');
	}
    };

    # Passed arguments take priority over everything.  After that are scratches beginning with fedex_
    # and then catalog variables beginning with FEDEX_, then globals, then any hard-coded defaults.
    # An exception is fixed attributes which always take full priority over everything unless
    # override_fixed is set, but we deal with that later.
    foreach ($::Scratch, $::Variable, $Global::Variable) {
	while (my ($key, $value) = each %$_) {
	    next unless $key =~ s/^fedex_//i;
	    my $l = lc $key;
	    $opt->{$l} = $value unless exists $opt->{$l};
	}
    }

    # Weight gets renamed because it is an ordered attribute.
    $opt->{lc 'RateRequestPackageSummaryTotalWeightValue'} = delete $opt->{weight} if defined $opt->{weight} && !defined $opt->{lc 'RateRequestPackageSummaryTotalWeightValue'};

    # Special functions performed by this tag:
    if (delete $opt->{list_services}) {
	return $output_list->([sort map { $_->{name} } values %fedex_services]);
    }


    # Args that don't get passed directly to FedEx:
    my $use_values = delete $opt->{'use_values'};
    my $use_cgi = delete $opt->{'use_cgi'};
    $use_values = 1 if (!defined $use_values && !$use_cgi);

    my $to_scratch = delete $opt->{to_scratch};
    delete $opt->{$to_scratch} if defined $to_scratch;
    my $from_scratch = delete $opt->{from_scratch};
    delete $opt->{$from_scratch} if defined $from_scratch;
    foreach ($to_scratch, $from_scratch) { $_ = lc if defined $_ }

    # Catch other cached objects by looking for hashrefs.  Also attributes that are explicity undefined.
    delete @{$opt}{grep { !defined $opt->{$_} || (ref $opt->{$_} && ref $opt->{$_} eq 'HASH') } keys %$opt};

    my $replyobj;

    my $override_fixed = delete $opt->{'override_fixed'};
    my $service = delete $opt->{service} || 'Rate';
    $service = lc $service;
    unless (exists $fedex_services{$service}) {
	::logError("[fedex-query]: ERROR: Invalid service $service.");
	return;
    }
    $service = $fedex_services{$service};

    my $reply = delete $opt->{'reply'};
    $reply = $service->{defaults}{reply} unless defined $reply;
    $reply = lc $reply;

    # Skip all this crap if from_scratch is defined.
    if (!defined $from_scratch) {

	# default cgi map.
	my %cgi_map = %{$service->{defaults}{cgi_map}};

	# Load up the cgi map from these other sources.
	foreach my $map
	    (
	     $Global::Variable->{FEDEX_CGI_MAP},
	     $::Variable->{FEDEX_CGI_MAP},
	     $::Scratch->{fedex_cgi_map},
	     $opt->{cgi_map},
	     )
	{
	    next unless defined $map;
	    foreach (split(/\s*[\n,]\s*/, $map)) {
		my ($key, $value) = split /\s*=\s*/;
		$cgi_map{lc $key} = lc $value;
	    }
	}

	my $list_elements = sub {
	    my $map = shift;
	    my %out;
	    foreach (values %$map) {
		next if $_->{name} eq $_->{element}{longname} && exists $out{$_->{element}{name}} && $out{$_->{element}{name}}[0] eq $_->{name};
		delete $out{$_->{element}{longname}};
		$out{$_->{name}} = [@{$_->{element}}{'longname', 'longdoc'}];
	    } 	

	    return $output_list->(\%out);
	};

	return $list_elements->($service->{request_name_map}) if (delete $opt->{list_request_elements});
	return $list_elements->($service->{reply_name_map}) if (delete $opt->{list_reply_elements});

	# Rudimentary check to see if the reply is valid.
	unless ($reply eq 'ref' || $reply =~ /_/ || exists $service->{reply_name_map}->{$reply}) {
	    ::logError("[fedex-query]: ERROR: Invalid reply element $reply.");
	    return;
	}

	# Get rid of the universal attributes, and other options that we don't need anymore.
	delete @{$opt}{qw(hide interpolate reparse cgi_map)};

	# Ready to set up the request structure.
	my %request;

	# Set all the passed attributes first.
	my %complex_opts;
	{
	    my @tmp = grep { /_/ } keys %$opt;
	    @complex_opts{@tmp} = delete @{$opt}{@tmp};
	}

	# Simple (pre-defined) options first.
	while (my ($key, $value) = each %$opt) {
	    unless (defined $service->{request_name_map}{$key}) {
		::logError("[fedex-query]: WARNING: Request element $key not found ... skipping.");
		next;
	    }

	    my $element = $service->{request_name_map}{$key}{element};

	    my $longname = $element->{longname};
	    my $ref = \%request;

	    if (ref $value && !$element->{array}) {
		logError("[fedex-query]: ERROR: Attempting to set an array where invalid for $longname.  Keeping first element and discarding the rest.");
		$value = $value->[0];
	    }
	    $value = [$value] if (!ref $value && $element->{array});

	    my @ar = @{$element->{path}};
	    pop @ar;
	    foreach (@ar) {
		if ($_->{array}) {
		    $ref->{$_->{name}}[0] ||= {};
		    $ref = $ref->{$_->{name}}[0];
		} else {
		    $ref->{$_->{name}} ||= {};
		    $ref = $ref->{$_->{name}};
		}
	    }

	    if (defined $ref->{$element->{name}}) {
		::logError("[fedex-query]: WARNING: Attempt to overwrite existing value for $longname.");
		next unless $key eq lc $longname;
	    }

	    $ref->{$element->{name}} = $value;
	}

	# ...and now the complex ones.
      COMPLEX: while (my ($key, $value) = each %complex_opts) {
	  my $type = $service->{request};
	  my $ref = \%request;

	  my @ar = split(/_/, $key);
	  my $last = pop @ar;
	  foreach (@ar) {
	      my $array;
	      $array = $1 if s/(\d+)$//;

	      unless (defined $type && exists $type->{elements}{$_}) {
		  ::logError("[fedex-query]: ERROR: Invalid request element $key.");
		  next COMPLEX;
	      }

	      my $element = $type->{elements}{$_};
	      $array ||= 0 if $element->{array};

	      if (defined $array && !$element->{array}) {
		  my $longname = $element->{longname};
		  ::logError("[fedex-query]: WARNING: Discarding invalid array index for $longname.");
		  undef $array;
	      }

	      if (defined $array) {
		  $ref->{$element->{name}}[$array] ||= {};
		  $ref = $ref->{$element->{name}}[$array];
	      } else {
		  $ref->{$element->{name}} ||= {};
		  $ref = $ref->{$element->{name}};
	      }

	      $type = $element->{type};
	  }

	  my $array;
	  $array = $1 if $last =~ s/(\d+)$//;

	  unless (defined $type && exists $type->{elements}{$last}) {
	      ::logError("[fedex-query]: ERROR: Invalid request element $key.");
	      next COMPLEX;
	  }
	  my $element = $type->{elements}{$last};
	  my $longname = $element->{longname};

	  # Deal with any array data that might not match up here:
	  if ($element->{array}) {
	      if (defined $array && ref $value) {
		  ::logError("[fedex-query]: WARNING: Attempt to set an array index in two different ways for $longname, discarding one.");
		  undef $array;
	      }

	      if (defined $array) {
		  my $tmp = $value;
		  $value = [];
		  $value->[$array] = $tmp;
	      }

	      if (!ref $value) {
		  $value = [$value];
	      }
	  } else {
	      if (defined $array) {
		  ::logError("[fedex-query]: WARNING: Discarding invalid array index for $longname.");
		  undef $array;
	      }

	      if (ref $value) {
		  logError("[fedex-query]: ERROR: Attempting to set an array where invalid for $longname.  Keeping first element and discarding the rest.");
		  $value = $value->[0];
	      }
	  }

	  if (defined $ref->{$element->{name}}) {
	      ::logError("[fedex-query]: WARNING: Overwriting existing value for $key.");
	  }

	  $ref->{$element->{name}} = $value;
      }

	{
	    my %defaults = %{$service->{defaults}{request}()};

	    {
		# Form variable defaults:
		my $set_form_defaults = sub {
		    my $cgi = shift;

		    while (my ($key, $value) = each %cgi_map) {
			if ($value =~ s/^\@//) {
			    my @values;
			    foreach (sort {
				$a =~ /(\d*)$/;
				my $aa = $1 || 0;
				$b =~ /(\d*)$/;
				my $bb = $1 || 0;
				$aa <=> $bb;
			    } keys %$cgi) {
				next unless /^\Q$value\E\d*$/i;
				push(@values, $cgi->{$_});
			    }

			    $defaults{$key} = [map { split(/\0/) } @values];
			} else {
			    while (my ($cgikey, $cgival) = each %$cgi) {
				$defaults{$key} = $cgival if lc $cgikey eq $value;
			    }
			}
		    }
		};
		$set_form_defaults->($::Values) if ($use_values);
		$set_form_defaults->(\%CGI::values) if ($use_cgi);
	    }

	    while (my ($key, $value) = each %defaults) {
		unless (defined $service->{request_name_map}{$key}) {
			::logError("[fedex-query]: WARNING: Request element $key not found ... skipping.");
			next;
		}

		my $element = $service->{request_name_map}{$key}{element};
		my $ref = \%request;

		my @ar = @{$element->{path}};
		pop @ar;
		foreach (@ar) {
		    if ($_->{array}) {
			$ref->{$_->{name}}[0] ||= {};
			$ref = $ref->{$_->{name}}[0];
		    } else {
			$ref->{$_->{name}} ||= {};
			$ref = $ref->{$_->{name}};
		    }
		}

		next if defined $ref->{$element->{name}};
		$ref->{$element->{name}} = $value;
	    }
	}

	# Set the fixed values
	foreach my $element (@{$service->{request_fixed}}) {
	    my $ref = \%request;

	    my @ar = @{$element->{path}};
	    pop @ar;
	    foreach (@ar) {
		if ($_->{array}) {
		    $ref->{$_->{name}}[0] ||= {};
		    $ref = $ref->{$_->{name}}[0];
		} else {
		    $ref->{$_->{name}} ||= {};
		    $ref = $ref->{$_->{name}};
		}
	    }

	    if (defined $ref->{$element->{name}}) {
		if ($override_fixed) {
		    next;
		} else {
		    my $longname = $element->{longname};
		    ::logError("[fedex-query]: WARNING: Attempt to override fixed element $longname.  Use override_fixed=1 if this is really what you want.");
		}
	    }

	    $ref->{$element->{name}} = $element->{fixed};
	}

	# Send the request
	my $method = $service->{method};
	eval { $replyobj = $service->{interface}->$method(\%request) };
	if ($@) {
		::logError("[fedex-query]: ERROR: $@");
		return;
	}

	unless ($replyobj) {
	    ::logError("[fedex-query]: ERROR: $replyobj");
	    return;
	}

	# Recursive sub to assemble a hashref from the result so we can cache it easier.
	my $to_hashref = sub {};
	$to_hashref = sub {
	    my ($obj, $seen) = @_;
	    $seen ||= {};

	    my $r = ref $obj;
	    return $obj unless $r;

	    if ($r eq 'ARRAY') {
		foreach (@$obj) {
		    $_ = $to_hashref->($_, $seen);
		}
		return $obj;
	    } elsif ($r eq 'HASH') {
		foreach (values %$obj) {
		    $_ = $to_hashref->($_, $seen);
		}
		return $obj;
	    } else {
		# This is an object:
		my $ostr = ::uneval($obj);
		return $ostr if $seen->{$ostr};
		$seen->{$ostr} = 1;
		my $r;
		{
			# These need to be reset to default for _DUMP to work.
			local $Data::Dumper::Indent;
			local $Data::Dumper::Terse;
			local $Data::Dumper::Deepcopy;
			$r = eval $obj->_DUMP;
		}
		$r = $to_hashref->($r, $seen);
		$r = (values %$r)[0];
		return $r;
	    }
	};


	$replyobj = $to_hashref->($replyobj);

	# Cache this object to a scratch.
	if (defined $to_scratch) {
	    $::Scratch->{$to_scratch} = {
		reply	=> $replyobj,
		service	=> lc $service->{name},
	    };
	}

    } else {
	unless (defined $::Scratch->{$from_scratch}) {
		::logError("[fedex-query]: ERROR: No such scratch $from_scratch.");
		return;
	}

	($replyobj, $service) = @{$::Scratch->{$from_scratch}}{qw(reply service)};
	$service = $fedex_services{$service};
    }

    # If the caller wants a ref just return the object.
    return $replyobj if $reply eq 'ref';

    # ...otherwise fetch what the caller wants.
    if ($reply =~ /_/) {
	# Complex
	my $type = $service->{reply};
	my $ref = $replyobj;
	my @ar = split(/_/, $reply);
	my $longname;
	foreach (@ar) {
	    # We allow two array notations.  One is a simple number at the end, the other is {a=>b} at the
	    # end, where a is the hash key and b is the value to look for.  The first element that has a
	    # matching key/value pair will be indexed.
	    my $array;
	    if (s/(\d+)$// || s/\{(\w+=>?\w+)\}$//) {
		$array = $1;
	    }

	    unless (defined $type && exists $type->{elements}{$_}) {
		::logError("[fedex-query]: ERROR: Element $_ not valid in reply $reply.");
		return;
	    }

	    my $element = $type->{elements}{$_};
	    $longname = $element->{longname};
	    $ref = $ref->{$element->{name}};
            unless (defined $ref) {
		my $longname = $element->{longname};
                ::logError("[fedex-query]: ERROR: Element $longname not found in reply $reply.");
                return;
            }

	    if (ref $ref eq 'ARRAY') {
		if (defined $array) {
		    if ($array =~ /(\w+)=>?(\w+)/) {
			# We need to walk through and find the element that matches.
			my $key = $1;
			my $val = $2;
			
			unless (defined $element->{type} && exists $element->{type}{elements}{$key}) {
			    ::logError("[fedex-query]: ERROR: Invalid array index in reply element $reply.");
			    return;
			}

			my $name = $element->{type}{elements}{$key}{name};
			for(my $i = 0; $i < @$ref; $i++) {
			    if (lc $ref->[$i]{$name}{value} eq $val) {
				$array = $i;
				last;
			    }
			    if ($array =~ /\D/) {
				::logError("[fedex-query]: ERROR: No matching index {$array} found for element $longname.");
				return;
			    }
			}
		    }

		    # One final check to make sure that the index is in bounds for the array.
		    if ($array =~ /\D/ || $array >= @$ref) {
			::logError("[fedex-query]: ERROR: Array Index $array out of bounds array index for element $longname.");
			return;
		    }

		    $ref = $ref->[$array];
		} else {
		    $ref = $ref->[0];
		}
	    } elsif (defined $array) {
		::logError("[fedex-query]: WARNING: Attempt to index an array for element $longname where none exists.");
	    }

	    $type = $element->{type};
	}

	$ref = $ref->{value};
	unless (defined $ref) {
	    ::logError("fedex-query]: Element $longname does not contain a reply value.");
	    return;
	}
	return $ref;

    } else {
	# Simple
	my $element = $service->{reply_name_map}{$reply}{element};
	my $ref = $replyobj;
	my @ar = @{$element->{path}};
	foreach (@ar) {
	    $ref = $ref->{$_->{name}};
	    unless (defined $ref) {
		my $longname = $_->{longname};
		::logError("[fedex-query]: ERROR: Element $longname not found in reply.");
		return;
	    }

	    $ref = $ref->[0] if ref $ref eq 'ARRAY';
	}

	$ref = $ref->{value};
	unless (defined $ref) {
	    my $longname = $element->{longname};
	    ::logError("[fedex-query]: ERROR: Element $longname does not contain a reply value.");
	    return;
	}
	return $ref;
    }
}

EOR
