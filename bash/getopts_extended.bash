#!/bin/false
# shellcheck shell=bash
#
# This file is meant to be sourced.  It will replace the getopts builtin with
# one that has added functionality.
#
# shellcheck disable=SC2142
alias getopts='_getopts "$#" "$@"'
_getopts(){
    local help usage
    # shellcheck disable=SC2154
    IFS= read -r -d '' help <<EOF
getopts optstring name [arg ...]
Parse option arguments.

Getopts is used by shell procedures to parse positional parameters
as options.

OPTSTRING contains the option letters to be recognized; if a letter
is followed by a colon (:), the option is expected to have an
argument which may optionally be separated from it by whitespace.
If a letter is followed by a question mark (?), the option may
optionally have an argument which should not be separated from it
by whitespace.

Each time it is invoked, getopts will place the next option in the
shell variable $name, initializing name if it does not exist, and
the index of the next argument to be processed into the first
element (element zero) of the array OPTIND.  OPTIND is initialized
to 1 each time the shell or a shell script is invoked.  When an
option has an argument, getopts places that argument into the shell
variable OPTARG.

Option grouping is supported.  When options are grouped the
position of the next option to be processed in the option group
will be stored in the second element of the OPTIND array (element
one).

Long options (of the form --name[(=| )value]) are supported.
Option names may be specified in the LONGOPTS associative array. The
keys to the array are the option names allowed. If the
corresponding value is set to a colon (:), the option is expected
to have an argument which may optionally be separated by either an
equal sign (=) or whitespace. If the value is a question mark (?),
the option may optionally have an argument which should be
separated by an equal sign (=). If the value is the empty string it
is not expected to contain an argument.

Getopts reports errors in one of two ways.  If the first character
of OPTSTRING is a colon, getopts uses silent error reporting.  In
this mode, no error messages are printed.  If an invalid option is
seen, getopts places the option character found into OPTARG.  If a
required argument is not found, getopts places a ':' into NAME and
sets OPTARG to the option character found.  If getopts is not in
silent mode, and an invalid option is seen, getopts places '?' into
NAME and unsets OPTARG.  If a required argument is not found, a '?'
is placed in NAME, OPTARG is unset, and a diagnostic message is
printed.

If the shell variable OPTERR has the value 0, getopts disables the
printing of error messages, even if the first character of
OPTSTRING is not a colon.  OPTERR has the value 1 by default.

Getopts normally parses the positional parameters, but if arguments
are supplied as ARG values, they are parsed instead.

Exit Status:
Returns success if an option is found; fails if the end of options is
encountered or an error occurs.
EOF
    local -a helpa
    readarray helpa <<<"$help"
    usage="getopts: usage: ${helpa[0]%$'\n'}"
    helpa=("${helpa[@]:1}")
    printf -v help '%s' "getopts: ${helpa[0]}" "${helpa[@]/#/    }"
    
    # This can't happen if the funtion is invoked from the alias wrapper.
    (( $#<1 )) && return 1

    # OPTERR defaults to 1.
    local OPTERR=$OPTERR
    [[ $OPTERR == '' ]] && OPTERR=1

    # Get the number of args into argc.
    local argc=$1
    shift

    # This can't happen either unless the function is invoked directly.
    (( $#<argc )) && return 1

    # Get the args themselves into argv.
    local -a argv=("${@:1:$argc}")
    shift "$argc"

    # Display help and exit.
    if [[ $1 == --help ]]; then
	printf '%s' "$help" >&2
	return 0
    fi
    
    # Two required args, otherwise display usage.
    (( $# < 2 )) && {
	printf '%s\n' "$usage" >&2
	return 1
    };
    local optstring=$1
    local -n _getopts_name=$2
    shift 2

    # Setting : to indicate special error handling.
    local special_error=0
    if [[ $optstring == :* ]]; then
	optstring=${optstring#:}
	special_error=1
	OPTERR=0
    fi
    
    # If there's any args left then we need to use them instead of the ones we
    # saved into argv.
    if (( $# )); then
	argc=$#
	argv=("$@")
    fi

    # Make sure OPTIND doesn't have a bad attribute
    if [[ ${OPTIND@a} == *r* ]]; then
	echo "getopts: OPTIND cannot be read only."
	return 1
    fi
    if [[ ${OPTIND@a} == *A* ]]; then
	unset OPTIND
    fi

    # Make sure OPTIND is an array
    if [[ ${OPTIND@a} != *a* ]]; then
	declare -gia OPTIND=("$OPTIND" 1)
    fi

    # Default both elements to 1
    (( OPTIND[0] )) || OPTIND[0]=1
    (( OPTIND[1] )) || OPTIND[1]=1
    
    # Grab the appropriate arg
    local arg=${argv[OPTIND[0]-1]}

    # Check for end of args
    if [[ $arg == '--' ]]; then
	(( ++OPTIND[0] ))
	OPTIND[1]=1
	OPTARG=
	_getopts_name=\?
	return 1
    fi
    
    # Must start with a dash (-).
    if [[ $arg != -* ]]; then
	OPTARG=
	_getopts_name=\?
	return 1
    fi

    # Long options processing
    _getopts_longopts || return "$(( $? - 1 ))"

    # Short options processing
    _getopts_shortopts || return "$(( $? - 1 ))"
}

#
# Check arg for long option and process.
# Will return an exit code of 0 to indicate we should carry on processing short
# opts.  Otherwise subtract one from the exit code and exit the parent function.
#
_getopts_longopts(){
    # Check to make sure that we're processing long opts and that this looks
    # like one.
    if (( OPTIND[1] > 1 )) || [[ ${LONGOPTS@a} != *A* || $arg != --* ]]; then
	return 0
    fi

    # This looks like a long opt.
    local n=${arg#--}
    n=${n%%=*}
    local v
    [[ $arg == *=* ]] && v=${arg#*=}

    # Pre set these.
    (( ++OPTIND[0] ))
    _getopts_name=\?
    OPTARG=
    (( special_error )) && OPTARG=$n

    # Illegal option check
    if [[ ! -v LONGOPTS[$n] ]]; then
	(( OPTERR )) && printf '%s: illegal option -- %s\n' "$0" "$n"
	return 1
    fi

    # Required arg check
    local flags=${LONGOPTS[$n]}
    if [[ $flags == : ]]; then
	[[ ! $v ]] && (( argc <= OPTIND[0] )) && {
	    (( special_error )) && _getopts_name=:
	    (( OPTERR )) && printf '%s: option requires an argument -- %s\n' \
				   "$0" "$n"
	    return 1
	}
	v=${argv[OPTIND[0]++-1]}
    fi

    # No arg check
    if [[ $flags != [:?] && $v ]]; then
	(( special_error )) && _getopts_name=
	(( OPTERR )) && printf '%s: option may not have an argument -- %s\n' \
			       "$0" "$n"
	return 1
    fi

    # Everything checks out.
    OPTIND[1]=1
    OPTARG=$v
    _getopts_name=$n
    return 1
}

#
# Check arg for short option and process.
# Subtract one from the exit code and exit the parent function.
#
_getopts_shortopts(){
    local n=${arg:OPTIND[1]++:1}
    local v
    
    # Illegal option check
    if [[ $optstring != *"$n"* ]]; then
	(( OPTERR )) && printf '%s: illegal option -- %s\n' "$0" "$n"
	return 1
    fi

    # Pre set these.
    local flags=${optstring#*"$n"}
    flags=${flags:0:1}
    [[ $flags == [:?] ]] && (( ++OPTIND[1] ))
    
    if (( ${#arg} <= OPTIND[1] )); then
	(( ++OPTIND[0] ))
	OPTIND[1]=1
    fi
    _getopts_name=\?
    OPTARG=
    (( special_error )) && OPTARG=$n

    # Required arg check and return arg passed after white space.
    if [[ $flags == : ]] && (( OPTIND[1] == 1 )); then
	(( OPTIND[0] >= argc )) && {
	    (( special_error )) && _getopts_name=:
	    (( OPTERR )) && printf '%s: option requires an argument -- %s\n' \
				   "$0" "$n"
	    return 1
	}
	OPTARG=${argv[OPTIND[0]++]}
	_getopts_name=$n
	return 1
    fi

    # Return arg passed without white space.
    if [[ $flags == [:?] ]] && (( OPTIND[1] > 1 )); then
	OPTARG=${arg:OPTIND[1]-1}
	_getopts_name=$n
	(( ++OPTIND[0] ))
	OPTIND[1]=1
	return 1
    fi

    # Return no arg passed
    _getopts_name=$n
    return 1
}
