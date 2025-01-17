#!/usr/bin/perl -I /opt/grnoc/venv/grnoc-tsds-services/lib/perl5
package GRNOC::TSDS::Parser;

use strict;
use warnings;

use feature 'switch';

use Carp;
use Marpa::R2;
use Tie::IxHash;
use Statistics::LineFit;
use Time::HiRes qw(gettimeofday tv_interval);
use Clone qw(clone);
use Math::Round qw( nlowmult );
use Data::Dumper;
use Sys::Hostname;
use List::Util qw(min max);
use Scalar::Util;
use POSIX;
use DateTime;

use GRNOC::Log;

use GRNOC::TSDS;
use GRNOC::TSDS::Constants;
use GRNOC::TSDS::MongoDB;
use GRNOC::TSDS::Parser::Actions;
use GRNOC::TSDS::Aggregate::Histogram;
use GRNOC::TSDS::Constraints;

### constants ###

use constant DEFAULT_GROUPING => "__DEFAULT_GROUPING__";
use constant TIMESTAMP_GROUP  => "__timestamp";
use constant DATA         => 'data';
use constant MEASUREMENTS => 'measurements';
use constant METADATA     => 'metadata';
use constant AGGREGATE    => 'aggregate';
use constant BNF_FILE => '/usr/share/doc/grnoc/tsds/query_language.bnf';

use constant AGGREGATE_AVERAGE    => 1;
use constant AGGREGATE_MAX        => 2;
use constant AGGREGATE_MIN        => 3;
use constant AGGREGATE_HIST       => 4;
use constant AGGREGATE_PERCENTILE => 5;
use constant AGGREGATE_SUM        => 6;
use constant AGGREGATE_COUNT      => 7;

### constructor ###

sub new {

    my $caller = shift;

    my $class = ref( $caller );
    $class = $caller if ( !$class );

    # create object
    my $self = {
	bnf_file      => BNF_FILE,
	temp_table    => '__workspace',
	temp_database => '__tsds_temp_space',
        temp_id       => Sys::Hostname::hostname . $$,
	@_
    };

    bless( $self, $class );

    # load up our bnf language definitions
    open(F, $self->{'bnf_file'}) or croak "Unable to open bnf_file: $!";
    my @lines = <F>;
    close(F);

    $self->bnf(join("\n", @lines));

    my $language = $self->bnf();
    $self->grammar(Marpa::R2::Scanless::G->new({source  => \$language}));

    # connect to mongo
    $self->mongo_rw( GRNOC::TSDS::MongoDB->new( config_file => $self->{'config_file'}, privilege => 'rw') );

    return $self;
}

### getters/setters ###

sub error {
    my $self = shift;
    my $err  = shift;

    if ($err){
	$self->{'error'} = $err;
	log_error($err);
    }

    return $self->{'error'};
}

sub total {
    my $self  = shift;
    my $total = shift;

    $self->{'query_total'} = $total if defined($total);
    return $self->{'query_total'};
}

sub total_raw {
    my $self      = shift;
    my $total_raw = shift;

    $self->{'query_total_raw'} = $total_raw if defined($total_raw);
    return $self->{'query_total_raw'};
}

sub actual_start {
    my $self         = shift;
    my $actual_start = shift;

    $self->{'query_actual_start'} = $actual_start if defined($actual_start);
    return $self->{'query_actual_start'};    
}

sub actual_end {
    my $self       = shift;
    my $actual_end = shift;

    $self->{'query_actual_end'} = $actual_end if defined($actual_end);
    return $self->{'query_actual_end'};    
}

sub mongo_rw {
    my $self  = shift;
    my $mongo = shift;

    $self->{'mongo_rw'} = $mongo if ($mongo);
    return $self->{'mongo_rw'};
}

sub temp_table {
    my $self = shift;
    my $name = shift;

    $self->{'temp_table'} = $name if ($name);
    return $self->{'temp_table'};
}

sub temp_database {
    my $self = shift;
    my $name = shift;

    $self->{'temp_database'} = $name if ($name);
    return $self->{'temp_database'};
}

sub temp_id {
    my $self = shift;
    my $name = shift;

    $self->{'temp_id'} = $name if ($name);
    return $self->{'temp_id'};
}

sub bnf {
    my $self = shift;
    my $bnf  = shift;

    $self->{'bnf'} = $bnf if ($bnf);
    return $self->{'bnf'};
}

sub grammar {
    my $self = shift;
    my $grammar  = shift;

    $self->{'grammar'} = $grammar if ($grammar);
    return $self->{'grammar'};
}

### public methods ###

sub evaluate {
    my $self  = shift;
    my $query = shift;
    my %args  = @_;

    # set a flag to let queries know whether they should force
    # some sort of constraint or not
    $self->{'force_constraint'} = $args{'force_constraint'};

    # remove our error flag from any previous run
    $self->{'error'} = undef;

    # clear flag indicating use of temp table
    $self->_used_temp_table(0);

    # remove any totals from previous run
    $self->{'query_total'} = undef;
    $self->{'query_total_raw'} = undef;

    log_info("Evaluating query: $query");

    my $token_start = [gettimeofday];

    my $tokens = $self->tokenize($query);

    log_debug("Tokenization complete in " . (tv_interval($token_start, [gettimeofday])) . " seconds");

    return if (! defined $tokens);

    # Wrap process tokens in eval to avoid crashing
    # if there are problems
    my $res;
    eval {
        $res = $self->_process_tokens($tokens, 0, $query);
    };
    if ($@){
        $self->error($@);
    }

    # If we used a temporary table, clean it out
    if ($self->_used_temp_table()){
        $self->_clean_temp_table();
    }

    if (defined($token_start) && defined($self->{'query_total'}) && defined($query)) {
    log_info("[tsds_trace]: Response Time: " . tv_interval($token_start, [gettimeofday]) . " seconds | Objects Returned: " . $self->{'query_total'} . " | Original Query: $query");
    }

    return $res;
}

sub tokenize {
    my $self  = shift;
    my $query = shift;

    my $error;
    my $value;

    my $parser = Marpa::R2::Scanless::R->new({grammar => $self->grammar(),
					      #trace_terminals => 2,
					      semantics_package => 'GRNOC::TSDS::Parser::Actions'});

    eval {
	$parser->read(\$query);
    };

    # There are two ways the query can fail. We can either have an invalid character
    # along the path (part 1) or we can have an entirely missing component (part 2)

    # bad syntax for query, bail out
    if ($@){
        my $raw_error = $@;

        log_debug("Found error while getting scanning query string: $raw_error");

        # THIS IS AN EXAMPLE
        # -------------------
        # No lexeme found at line 1, column 103
        # * String before error: ), aggregate(values.output, 182, average) between(
        # * The error was at line 1, column 103, and at character 0x005c '\', ...
        # * here: \\"02/23/2016 16:21:33 UTC\\",\\"02/24/2016 16:21:

        my $string_before = "";
        my $string_at     = "";
        my $col;

        if ($raw_error =~ /String before error: (.+)/){
            $string_before = $1;
        }
        if ($raw_error =~ /at line \d+, column (\d+)/){
            $col = $1;
        }
        if ($raw_error =~ /here: (.+)/){
            $string_at = $1;
            $string_at =~ s/\\\\/\\/g;
        }
     
        $error  = "Syntax error in query: " . $string_before . "*HERE*>>>" . substr($string_at, 0, 1) . "<<<*HERE*" . substr($string_at, 1) . "\n";
    }
    # In this case we probably have an entire missing section vs having a section
    # with bad syntax or wrong characters
    else {
        $value = $parser->value();

        if (! defined $value){
            log_debug("Found error while getting Marpa parser value");

            # Figure out what the last successfully parsed part of the query was so that
            # we can point the user to the right location
            my ( $g1_start, $g1_length ) = $parser->last_completed('query');
            if (defined $g1_start){
                my $last_expression = $parser->substring( $g1_start, $g1_length );
                my $quoted = quotemeta($last_expression);
                $query =~ /$quoted(.+)/;
                $error = "Syntx error in query: " . $last_expression . "*HERE*>>>" . $1 . "<<<*HERE*";
            }
            else {
                $error = "Error getting parser value: " . $parser->show_progress();
            }
        }
    }

    if (defined $error){
        $self->error($error);
        return;
    }
    
    my $tokens = ${$value};
    
    return $tokens;
}

### private methods ###

sub _used_temp_table {
    my $self = shift;
    my $flag = shift;

    $self->{'_used_temp_table'} = $flag if (defined $flag);
    return $self->{'_used_temp_table'};
}

sub _process_tokens {
    my $self        = shift;
    my $tokens      = shift;
    my $is_subquery = shift;
    my $text_query  = shift;

    my $query_time_start = [gettimeofday];

    log_debug("Tokens are: ", {
        filter => \&Data::Dumper::Dumper,
        value  => $tokens
    });

    # 1st general step is to grab out all of our tokens
    my $get_fields       = $self->_get_get($tokens);    

    my $field_names      = $self->_get_field_names($get_fields);

    my $from_field       = $self->_get_from($tokens);

    my $with_details     = $self->_get_with_details($tokens);

    my ($where_fields, $where_names) = $self->_get_where($tokens);
    
    my $having_fields    = $self->_get_having($tokens, $get_fields);

    my $between_fields   = $self->_get_between($tokens);

    my ($by_tokens, $by_in_time) = $self->_get_by($tokens);

    my $order_fields     = $self->_get_order($tokens);

    my ($limit, $offset) = $self->_get_limit_offset($tokens);

    # Next step is to actually grab the data
    my $doc_symbols = {};

    # If we had a subquery, evaluate that and use its answer
    if (ref $from_field eq 'ARRAY'){
        log_debug("Evaluating inner query");
        my $inner_query = shift @$from_field;

        # the subquery will be stored in a temp table in mongo and it will return the
        # field mappings from the last query. This is to get around the fact that you cannot
        # store certain characters as mongo fields so it arbitrarily assigns them new ones
        $doc_symbols = $self->_process_tokens($inner_query, 1, $text_query);
        $from_field  = $self->temp_database();

        return if (! defined $doc_symbols);
    }


    # Figure out whether we're doing an order on the metadata
    # or the data itself, only applicable to the main database queries
    my $need_all = 0;
    if ((keys %$having_fields) > 0){
        $need_all = 1;
    }
    if ($from_field ne $self->temp_database() && @$order_fields > 0){
        my $first_order = $order_fields->[0][0];

        # is this a nice vanilla data field?
        if (! $self->_is_meta_field([$first_order])){
            $need_all = 1;
        }

        # need to figure out if this was a renamed value field or not
        foreach my $get_field (@$get_fields){
            my $rename = $self->_find_rename($get_field);

            if ($rename && $rename eq $first_order){
                # get values.input as foo
                my $original_field_name = $self->_get_base_field_extent($get_field);

                if (! $self->_is_meta_field([$original_field_name])){
                    $need_all = 1;
                }
            }
        }
    }

    log_debug("Getting all results: $need_all");

    my $inner_result = $self->_query_database(
            from           => $from_field,
            where          => $where_fields,
            where_names    => $where_names,
            fields         => $get_fields,
            between        => $between_fields,
            by             => $by_tokens,
            order          => $order_fields,
            need_all       => $need_all,
            limit          => $limit,
            offset         => $offset,
            symbols        => $doc_symbols,
	    text_query     => $text_query
        );
   
    return if (! defined $inner_result);

    # apply the specified by grouping or the default
    # in the case of an outer query there might be no additional grouping
    if (! @$by_tokens && $from_field ne $self->temp_database()){
        $by_tokens = [DEFAULT_GROUPING];
    }

    if (@$by_tokens > 0){
        $inner_result = $self->_apply_by( $by_tokens, $inner_result, $get_fields, $by_in_time, $between_fields );
    }

    # after applying "by" we can prune out all the start/end times of the documents
    # these are needed for originally querying, associating to metadata, and possibly
    # grouping by time component, but aren't needed after this
    map{ delete $_->{'start'}; delete $_->{'end'} } @$inner_result;

    # Now apply the aggregations on the data sets
    my $final_results = $self->_apply_aggregation_functions($inner_result, $get_fields, $with_details, $between_fields);

    return if (! defined $final_results);

    # If we have a "having" clause we need to write out the initial results to a temporary
    # database and execute another query against that using the having as the "where" clause
    if ((keys %$having_fields) > 0){
        my $temp_result = $self->_write_temp_table($final_results);
        return if (! defined $temp_result);

        $final_results = $self->_query_database(
            from           => $self->temp_database(),
            where          => $having_fields,
            where_names    => $where_names,
            fields         => $get_fields,
            between        => $between_fields,
            by             => $by_tokens,
            order          => $order_fields,
            need_all       => $need_all,
            limit          => $limit,
            offset         => $offset,
            symbols        => $temp_result
        );

        return if (! defined $final_results);
    }

    # Now order our result set if applicable
    if (@$order_fields){
        $final_results = $self->_apply_order($final_results, $order_fields);
    }

    return if (! defined $final_results);

    # If we were ordering by data we need to apply limit/offset if necessary to the
    # final sorted data
    if (defined $limit && ($need_all || $from_field eq $self->temp_database()) && (keys %$having_fields) == 0){

        # if we're limiting as a result of being on an outer query with a limit
        # set our total to the current possible results now
        if ($from_field eq $self->temp_database()){
            $self->total(scalar @$final_results);
            $self->total_raw(scalar @$final_results);
        }

	# If we were doing a data fetch we only set the "raw" limit in
	# query database, now that we have done all of the grouping
	# we know what the final set looks like before doing limit
	if (! defined $self->total()){
            $self->total(scalar @$final_results);
	}

        $final_results = $self->_apply_limit_offset($final_results, $limit, $offset);
    }

    # Done!

    # if we're a subquery, write our answer back to a temp table in mongo
    # so the outer queries can use that
    if ($is_subquery){
        my $temp_result = $self->_write_temp_table($final_results);
        log_debug("Inner query completed in " . tv_interval($query_time_start, [gettimeofday]) . " seconds");
        return $temp_result;
    }

    log_info("Data for query returned in " . tv_interval($query_time_start, [gettimeofday]) . " seconds");

    # if we haven't calculated the total results earlier, such as doing a limit query,
    # just document the total that we have right at the end
    if (! defined $self->total()){
        $self->total(scalar @$final_results);
    }
    if (! defined $self->total_raw()){
        $self->total_raw(scalar @$final_results);
    }

    # otherwise we're all done and can return the set upwards
    return $final_results;
}

sub _write_temp_table {
    my $self    = shift;
    my $results = shift;

    # make sure we get rid of everything already in there
    # if applicable
    $self->_clean_temp_table() or return;
    
    # flag that something during this evaluation used a temp table
    # so we know whether or not we have to clean up at the end
    $self->_used_temp_table(1);

    # make sure that it will clean up after itself if something goes wrong or
    # we don't re-enter here
    my $temp_collection = $self->mongo_rw()->get_collection($self->temp_database(),
							    $self->temp_table());
    

    if (! $temp_collection){
	$self->error($self->mongo_rw()->error());
	return;
    }

    my %symbols;

    foreach my $result (@$results){
	$self->_symbolize($result, \%symbols) or return;

        # flag this doc as belonging to this process
        $result->{'__tsds_temp_id'} = $self->temp_id();

	eval {
	    my $res    = $temp_collection->insert_one($result);
	    my $doc_id = $res->{'value'};
	};

	if ($@){
	    $self->error("Error while inserting into temp table.");
	    return;
	}
    }

    log_debug("Symbols generated are: ", {filter => \&Data::Dumper::Dumper,
					  value  => \%symbols});

    return \%symbols;
}

sub _clean_temp_table {
    my $self = shift;

    my $temp_collection = $self->mongo_rw()->get_collection($self->temp_database(),
                                                            $self->temp_table());

    my $res = $temp_collection->delete_many({"__tsds_temp_id" => $self->temp_id()});    

    $self->_used_temp_table(0);

    return 1;
}

sub _symbolize {
    my $self    = shift;
    my $doc     = shift;
    my $symbols = shift;


    # only need to symbolize keys in a hash, don't care about anything else
    return 1 if (ref $doc ne 'HASH');

    my $string = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890';

    my @keys = keys %$doc;

    if (@keys - 1 > length($string)){
	$self->error("Unable to symbolize keys, too long.");
	return;
    }

    for (my $i = 0; $i < @keys; $i++){
	my $old_key = $keys[$i];
	my $new_key;

	# was there already a mapping for this field name in another
	# doc? If so re-use that
	foreach my $existing_key (keys %$symbols){
	    $new_key = $existing_key if ($symbols->{$existing_key} eq $old_key);
	}

	# if we haven't seen this field before create a new key for it
	$new_key = substr($string, $i, 1) unless ($new_key);

	# remap the key in the doc
	$symbols->{$new_key} = $old_key;
	$doc->{$new_key}     = $doc->{$old_key};
	delete $doc->{$old_key};

	# recurse to any subdocuments
	$self->_symbolize($doc->{$new_key}, $symbols) or return;
    }

    return 1;
}

sub _get_where {
    my $self     = shift;
    my $tokens   = shift;

    my @copy = @$tokens;

    my $where_fields;

    # int he tokens we will have the 'where' token followed by the where fields
    while (@copy){
	my $token = shift @copy;

	if (ref $token eq 'ARRAY' && $token->[0] eq 'where'){
	    $where_fields = $token->[1];
	    last;
	}
    }

    return {} if (! $where_fields);

    log_debug("Raw Where fields: ", {filter => \&Data::Dumper::Dumper,
				     value  => $where_fields});

    my ($parsed_where, $where_names) = $self->_where_helper($where_fields);

    return if ($self->error());

    log_debug("Parsed Where fields: ", {filter => \&Data::Dumper::Dumper,
					value  => $parsed_where});


    log_debug("Unique where names: ", {filter => \&Data::Dumper::Dumper,
				       value  => $where_names});

    return ($parsed_where, $where_names);
}


# This applies to both "having" and "where" parsing since they are both
# really the same set of data
sub _where_helper {
    # can legitimately recurse > 100 times, don't spam logs with warnings
    no warnings 'recursion'; 
    my $self   = shift;
    my $tokens = shift;
    my $no_type_check = shift;

    my $mappings = {
	'>'    => '$gt',
	'>='   => '$gte',
	'<'    => '$lt',
	'<='   => '$lte',
	'='    => '=',
	'!='   => '$ne',
	'like' => '$regex'
    };

    log_debug("Where helper Examining: ", {filter => \&Data::Dumper::Dumper,
					   value  => $tokens});


    my %unique;
    my %cooked;

    # go through and cook them
    while (@$tokens){

	my $field    = shift @$tokens;
	my $operator = shift @$tokens;
	my $field2   = shift @$tokens;

	if (! $operator && ref $field eq 'ARRAY'){
	    return $self->_where_helper($field);
	}

	# parse the Date token specially into just its epoch time
	if (defined( $field2 ) && $field2 =~ /^Date\((\d+)\)$/){
	    $field2 = $1;
	}

	if (! ref $field){
	    $unique{$field} = 1;
	}

	# mongo driver is very touchy about types, so try to
	# abstract that a bit so that we find either version
	# 'like' and 'not like' however should always be treated
	# like strings
	if (! $no_type_check && defined( $field2 ) && $field2 =~ /^-?\d+(\.\d+)?$/ && $operator ne 'like' && $operator ne 'not like'){
	    my ($res, $uniq)   = $self->_where_helper([$field, $operator, $field2], 1);
	    my ($res2, $uniq2) = $self->_where_helper([$field, $operator, $field2 * 1], 1);
            # if we're doing negation or positive, invert the operator for mongo
	    my $mongo_op = $operator eq '!=' ? '$and' : '$or';
	    push(@{$cooked{$mongo_op}}, $res);
	    push(@{$cooked{$mongo_op}}, $res2);	    
	    %unique = (%unique, %$uniq);
	    %unique = (%unique, %$uniq2);
	}
	# translate between into an and statement
	elsif ($operator eq 'between'){
	    my $val1 = $field2;
	    my $val2 = shift @$tokens;
	    my ($res1, $uniq1) = $self->_where_helper([$field, ">=", $val1]);
	    my ($res2, $uniq2) = $self->_where_helper([$field, "<=", $val2]);

	    push(@{$cooked{'$and'}}, $res1);
	    push(@{$cooked{'$and'}}, $res2);
	}
	elsif ($operator eq 'in'){
	    my @in_fields;
	    while (my $token = shift @$field2){
		push(@in_fields, $token->[0]);
	    }
	    $cooked{$field} = {'$in' => \@in_fields};
	}
	elsif ($operator eq 'and' || $operator eq 'or'){
	    foreach my $f (($field, $field2)){
		my ($res, $uniq) = $self->_where_helper($f);

                my $mongo_op = '$'. $operator;

                # If we're looking at the next operator and it's the same as the current one
                # we can merge the results together into a single mongo query - this avoids the
                # problem of having overly nested $or clauses or something which Mongo doesn't
                # like. It's also more efficient.
                if (ref $res eq 'HASH' && exists $res->{$mongo_op}){
                    my $inner_res = $res->{$mongo_op};

                    # $and and $or always deal with arrays
                    foreach my $el (@$inner_res){
                        push(@{$cooked{$mongo_op}}, $el);
                    }
                }
                else {
                    push(@{$cooked{$mongo_op}}, $res);
                }

		%unique = (%unique, %$uniq);
	    }
	}
	elsif ($operator eq 'not like'){
	    $cooked{$field} = {'$not' => qr/$field2/i};
	}
	else {
	    if (! exists $mappings->{$operator}){
		$self->error("Unknown operator \"$operator\"");
		return;
	    }

	    if ($operator eq "="){
		$cooked{$field} = $field2;
	    }
	    elsif ($operator eq 'like'){
		$cooked{$field} = {'$regex' => qr/$field2/i};
	    }
	    else {
		my $symbol = $mappings->{$operator};
		$cooked{$field} = {$symbol => $field2};
	    }
	}

    }

    return (\%cooked, \%unique);
}

sub _get_having {
    my $self   = shift;
    my $tokens = shift;

    my @copy = @$tokens;

    my $having_fields;

    while (@copy){
	my $token = shift @copy;

	if (ref $token eq 'ARRAY' && $token->[0] eq 'having'){
	    $having_fields = $token->[1];
	    last;
	}
    }

    return {} if (! $having_fields);

    log_debug("Raw having fields: ", {filter => \&Data::Dumper::Dumper,
                                      value  => $having_fields});

    my ($parsed_having, $where_names) = $self->_where_helper($having_fields);

    return if ($self->error());
    
    log_debug("Parsed having fields: ", {filter => \&Data::Dumper::Dumper,
                                         value  => $parsed_having});

    return $parsed_having;
}

sub _get_between {
    my $self   = shift;
    my $tokens = shift;

    my @copy = @$tokens;

    while (@copy){
	my $token = shift @copy;

	return if ( !defined( $token ) );

	# don't accidentally go into the where clause since there can be
	# between statements in there
	return if ($token eq 'where');
	last if ($token eq 'between');
    }

    my $between_fields = shift @copy;

    # the top level between clause must be of two date objects
    # so pull out their inner epoch time
    my @result;
    foreach my $field (@$between_fields){
	$field =~ /Date\((\d+)\)/;
	push(@result, int($1));

    }

    log_debug("Between fields: ", {filter => \&Data::Dumper::Dumper,
				   value  => \@result});

    return \@result;
}

sub _get_from {
    my $self   = shift;
    my $tokens = shift;

    my @copy = @$tokens;

    # in the tokens we will have the 'from' token followed by the from fields
    while (@copy){
	my $token = shift @copy;
	last if ( defined( $token ) && $token eq 'from' );
    }

    my $from_fields = shift @copy;

    log_debug("From fields: ", {filter => \&Data::Dumper::Dumper,
				value  => $from_fields});

    return $from_fields;
}

sub _get_with_details {
    my $self   = shift;
    my $tokens = shift;

    my @copy = @$tokens;

    while (@copy){
	my $token = shift @copy;

	if ( defined( $token ) && $token eq 'with details' ){
	    log_debug("With details found");
	    return 1;
	}
    }

    log_debug("With details not found");
    return 0;
}

sub _get_get {
    my $self   = shift;
    my $tokens = shift;

    my @copy = @$tokens;

    while (@copy){
	my $token = shift @copy;
	last if ($token eq 'get');
    }

    my $get_fields = shift @copy;

    log_debug("Get fields: ", {filter => \&Data::Dumper::Dumper,
			       value  => $get_fields});

    return $get_fields;
}

sub _get_field_names {
    my $self       = shift;
    my $get_tokens = shift;

    my %names;

    foreach my $token (@$get_tokens){
        my $parts = $self->_get_get_token_fields($token);

        foreach my $part (@$parts){
            my $name = $self->_get_base_field_extent($part);
            $names{$name} = 1;
        }
    }

    my @keys = keys %names;

    log_debug("Field names are: ", {filter => \&Data::Dumper::Dumper,
				    value  => \@keys});

    return \%names;
}

sub _get_order {
    my $self   = shift;
    my $tokens = shift;

    my @copy = @$tokens;

    my $order_fields;

    while (@copy){
	my $token = shift @copy;

	if (ref $token eq 'ARRAY' && $token->[0] eq 'ordered'){
	    $order_fields = $token->[1];
	    last;
	}
    }

    # order fields are optional, might be nothing
    $order_fields ||= [];

    # add in default sort order if not specified
    for (my $i = 0; $i < @$order_fields; $i++){
	my $field = @$order_fields[$i];

	if (@$field != 2){
	    @$order_fields[$i] = [$field, 'ASC'];
	}

	# Fix up the name, the "field" specification in the BNF
	# strips out all the symbols such as "average(values.input)"
	# so we need to detect that and recreate it
	my $field_name       = $order_fields->[$i][0];

	if (ref $field_name eq 'ARRAY'){
	    my $fixed_field_name = shift @$field_name;
	    if (@$field_name > 0){
		$fixed_field_name .= "(" . join(", ", @$field_name) . ")";
	    }

	    $order_fields->[$i][0] = $fixed_field_name;
	}

    }

    log_debug("Order fields: ", {filter => \&Data::Dumper::Dumper,
				 value  => $order_fields});

    return $order_fields;
}

sub _get_limit_offset {
    my $self   = shift;
    my $tokens = shift;

    my @copy = @$tokens;

    my $limit;
    my $offset;

    while (@copy){
	my $token = shift @copy;

	if (ref $token eq 'ARRAY' && $token->[0] eq 'limit'){
	    $limit  = int($token->[1]);
	    $offset = int($token->[3]);
	    last;
	}

    }

    log_debug("Limit: " . ($limit ? $limit : "no limit")
	      .
	      " Offset: " . ($offset ? $offset : "no offset"));

    return ($limit, $offset);
}

sub _get_by {
    my $self   = shift;
    my $tokens = shift;

    my @copy = @$tokens;

    my $by_fields;
    my $group_time = 0;

    while (@copy){
	my $token = shift @copy;

	next if (! defined $token);

	if ($token eq 'by'){
	    $by_fields = shift @copy;
	}
	if (ref $token eq 'ARRAY' && $token->[0] eq 'by'){
	    $by_fields = $token->[1];
	}
    }

    # by fields are optional, might be no grouping
    $by_fields ||= [];

    log_debug("Raw by fields: ", {filter => \&Data::Dumper::Dumper,
				  value  => $by_fields});
    
    # Figure out if grouping by time is a part of this
    # We don't actually need it to remain in the group by
    for (my $i = @$by_fields - 1; $i >= 0; $i--){
	my $by_field = $by_fields->[$i];
	if (ref $by_field eq 'ARRAY'){
	    for (my $j = @$by_field - 1; $j >= 0; $j--){
		my $sub_field = $by_field->[$j];
		if ($sub_field eq TIMESTAMP_GROUP){
		    $group_time = 1;
		    splice(@$by_field, $j, 1);
		}
	    }
	}
	else {
	    if ($by_field eq TIMESTAMP_GROUP){
		$group_time = 1;
		splice(@$by_fields, $i, 1);
	    }
	}
    }

    log_debug("Final by fields: ", {filter => \&Data::Dumper::Dumper,
				    value  => $by_fields});
    log_debug("Grouping by time: $group_time");


    return ($by_fields, $group_time);
}


sub _query_database {

    my ( $self, %args ) = @_;

    my $db_name         = $args{'from'};
    my $where_fields    = $args{'where'};
    my $where_names     = $args{'where_names'};
    my $fields          = $args{'fields'};
    my $between_fields  = $args{'between'};
    my $by_fields       = $args{'by'};
    my $order_fields    = $args{'order'};
    my $need_all        = $args{'need_all'};
    my $limit           = $args{'limit'};
    my $offset          = $args{'offset'};
    my $doc_symbols     = $args{'symbols'};
    my $text_query      = $args{'text_query'};

    my $queried_field_names = $self->_get_field_names( $fields );

    my $start;
    my $end;
    my $metadata = {};

    # if we're trying to limit the query we need at least one by field
    # to use to make the determination of what we're limiting on
    if ($limit && @$by_fields < 1){
        $self->error("Unable to limit a query without a by clause.");
        return;
    }

    # If we're querying only a single field and we're also grouping by it
    # we can optimize the query to only ask mongo for distinct values
    my $use_distinct = 0;
    if (keys %$queried_field_names == 1 && @$by_fields == 1 && exists $queried_field_names->{$by_fields->[0]}){
        log_debug("Optimizing to use distinct due to single select field and by statement");
        $use_distinct = 1;
    }

    # If we're going to be grouping by something we need it in the output
    foreach my $by_field (@$by_fields){        

        # a by with some uniqueness on subfield selection
        if (ref $by_field eq 'ARRAY'){
            # the original field we're doing the by on
            $queried_field_names->{$by_field->[0]} = 1;

            # also need to ask for the subfields
            foreach my $sub_by (@{$by_field->[2]}){
                $queried_field_names->{$sub_by} = 1;
            }
        }
        # simple by field
        else {
            $queried_field_names->{$by_field} = 1;
        }
    }

    # Get a reference to our database
    my $database = $self->mongo_rw()->get_database($db_name);

    if (! defined $database){
        $self->error($self->mongo_rw()->error());
        return;
    }

    # are we querying a temp table or the real thing?
    if ($db_name eq $self->temp_database()){

        # if it's a temp table, just find everything from mongo
        undef %$queried_field_names;
    }
    else {
        if (! $between_fields){
            $self->error("Querying the main data storage requires a between clause");
            return;
        }

        # if we're querying the main data collection, check to see if we're enforcing a constraint
        if ($self->{'force_constraint'} && ! $limit && (keys %$where_names) == 0){
            $self->error("Unable to issue an unconstrained query to data collection.");
            return;
        }

        # load the metadata about this collection so we can use it to figure out
        # things like needing to unwind later
        $metadata = $database->get_collection(METADATA)->find_one();

        # we need to make sure that any fields in the where clause actually exist and are
        # properly indexed to help guide mongo away from doing any massive table scans
        return if (! $self->_verify_where_fields($metadata, $where_names));


        # we need start/end times to do some calculations on the values
        $queried_field_names->{'start'}      = 1;
        $queried_field_names->{'end'}        = 1;
        $queried_field_names->{'interval'}   = 1;
        $queried_field_names->{'identifier'} = 1;

        # we need to round align start to the document sizes so that we don't miss a document where the
        # latter part should be in this query but the beginning is before
        $start = $between_fields->[0];
        $end   = $between_fields->[1];
    }

    my $meta_where_fields = clone( $where_fields );

    # only look at measurements that were active at some point
    # during this timeframe
    my $time_or_clause = $self->_generate_time_clause($start, $end);

    if (exists $meta_where_fields->{'$and'}){
        push(@{$meta_where_fields->{'$and'}}, {'$or' => $time_or_clause});
    }
    else {
        $meta_where_fields->{'$and'} = [{'$or' => $time_or_clause}];
    }

    # parse any metadata constraints defined for this network
    if (defined($self->{'constraints_file'})) {
        my $constraints = GRNOC::TSDS::Constraints->new( config_file => $self->{'constraints_file'} );

        if ($db_name ne $self->temp_database() && ! grep({$_ eq $db_name} @{$constraints->get_databases()})){
	    $self->error("Not permitted to run query on $db_name");
	    return;
	}

        my $constraint_query = $constraints->parse_constraints( database => $db_name );

        if ( $constraint_query ) {
   
     	    if (exists $meta_where_fields->{'$and'}){
	    
	        push(@{$meta_where_fields->{'$and'}}, @{$constraint_query->{'$and'}} );
	    }
	    else {
	    
	        $meta_where_fields->{'$and'} = $constraint_query->{'$and'};
	    }
        }
    }

    # if we're limiting the query, we first need to do a subquery to determine the
    # narrowed window on things we're limiting on
    # if we're ordering by a value, don't do any limit on the metafields since we're
    # going to be doing that later after the data is accumulated
    if (! $need_all && $db_name ne $self->temp_database() && $limit){
        my $meta_start = [gettimeofday];
        my $limit_result = $self->_get_meta_limit_result(database    => $database,
                                                         metadata    => $metadata,
                                                         where       => $meta_where_fields,
                                                         limit       => $limit,
                                                         offset      => $offset,
                                                         by          => $by_fields,
                                                         order       => $order_fields);

        my $meta_end = [gettimeofday];

        log_warn("Time for meta limit: " . tv_interval($meta_start, $meta_end));


        # error?
        return if (! defined $limit_result);

        # if we couldn't find anything within the limit offset then we're done and
        # can just bail out
        if (! @$limit_result){
            log_info("No limiting fields found, exiting query.");
            return [];
        }
	
        my @or;
	
        foreach my $point (@$limit_result){
            my @and;
            my $value = $point->{'_id'};
	    
            foreach my $key (keys %$value){
		push(@and, {$key => $value->{$key}});
            }
	    
            push(@or, {'$and' => \@and});
        }
	
        if (exists $meta_where_fields->{'$and'}){
            push(@{$meta_where_fields->{'$and'}}, {'$or' => \@or});
        }
        else {
            $meta_where_fields->{'$or'} = \@or;
        }

    }

    # for timing how long queries take
    my $timing_start = [gettimeofday];

    # If we're using distinct we do a slightly different query because the driver handles
    # them differently for some reason. Distinct queries won't have data so we can
    # skip ahead and just return the unique values found.
    if ($use_distinct){
        my $field = $by_fields->[0];

        my $collection_name;
        if ($db_name eq $self->temp_database()){
            $collection_name = $self->temp_table();
        }
        else {
            $collection_name = MEASUREMENTS;
        }

        return $self->_get_distinct_fields(
            database        => $database,
            collection_name => $collection_name,
            key             => $field,
            query           => $meta_where_fields
        );
    }


    # if we're doing a direct data query we need to first
    # query the measurements table to grab all the identifiers
    # that we'll actually be needing in lieu of the actual where
    # clauses that got passed in
    my %meta_merge_docs;
    my @identifiers;

    if ($db_name ne $self->temp_database()){

        # determine which fields we need to unwind in our where clause
        my @unwind = $self->_get_unwind_operations($metadata, $queried_field_names, {});

        # if we're unwinding we need to match again at the end on the unwound fields to make sure
        # we're only including documents with that match in it vs some other element
        # in the array causing a match before unwinding
        if (@unwind > 0){
            push(@unwind, {'$match' => $meta_where_fields});
        }

        my $measurements = $database->get_collection(MEASUREMENTS);

        log_debug("Measurements query issued to Mongo: ", {filter => \&Data::Dumper::Dumper,
                                   value  => $meta_where_fields});

        my @aggregate_results;
        eval {

	    my @keys = keys( %$queried_field_names );

	    foreach my $key ( @keys ) {

		delete( $queried_field_names->{$key} ) if ( $key =~ /^values\./ );
	    }
	    
            @aggregate_results = $measurements->aggregate([{'$match' => $meta_where_fields},
                                                           @unwind,
                                                           {'$project' => $queried_field_names}
                                                          ])->all();
        };

        if ($@){
            $self->error("Error querying measurement database: $@");
            return;
        }

        foreach my $doc (@aggregate_results){
            my $identifier = $doc->{'identifier'};            
            push(@{$meta_merge_docs{$identifier}},  $doc);
            push(@identifiers, $identifier);
        }

        # if there were no matches, no need to continue on
        if (! @identifiers){
            log_debug("No identifiers found in measurements, returning empty.");
            return [];
        }

        # If we're ordering by data we'll need to mark how many total raw results there were. When ordering
        # by metadata this is handled in the _get_meta_limit_result method but that's not called
        # when doing data sorting
        if ($need_all){
            $self->total_raw(scalar @identifiers);
        }
    }

    log_debug("Where query post identifiers: ", {
        filter => \&Data::Dumper::Dumper,
        value  => $where_fields
    });

    # get all of the available low-res aggregate data stores in this database
    my $aggregates = $self->_get_aggregates( database => $database );

    # determine the best data store to use for every non-meta field we're querying
    my $data_field_map = {};
    my $data_field_hist_map = {}; #keep track of whether or not we need to include histogram

    foreach my $field ( @$fields ) {
        my $parts = $self->_get_get_token_fields($field);

        foreach my $part (@$parts){
            my @field_data = $self->_get_base_field_extent($part);
            
            my $name      = $field_data[0];
            my $extent    = $field_data[1];
            my $histogram = $field_data[2];
            
            # is this an outer temp db query?
            if ( $db_name eq $self->temp_database() ) {
                $data_field_map->{$self->temp_table()}{$name} = 1;
                next;
            }

            # dont need to worry about meta fields for data queries
            next if ( $self->_is_meta_field( $part ) );
            
            # did they ask for a > 1 resolution, ie some amount of aggregation
            if ($extent > 1){
                
                # what is the best data aggregate to use for this field?
                my $aggregate = $self->_get_best_aggregate( extent => $extent,
                                                            aggregates => $aggregates );
                
                $data_field_map->{$aggregate}{$name} = 1;
                
                # determine if we need to include a histogram in our query results for this value
                if( $histogram ){
                    $data_field_hist_map->{$aggregate}{$name} = 1;
                }

                # if we're doing an extent > 1, we might need to adjust the start/end times
                # to account for a misaligned query. ie if they're asking for day aggregates
                # but our query doesn't even span a full day we need to expand the timerange to get
                # the best possible fit
                my $floored = floor($start / $extent) * $extent;
                my $ceiled  = ceil($end / $extent) * $extent;

                if ($floored != $start || $ceiled != $end){

                    log_debug("Changing start from $start to $floored due to aggregation $extent");
                    log_debug("Changing start from $end to $ceiled due to aggregation $extent");

                    $start = $floored;
                    $end   = $ceiled;
                }
            }
            
            # regular get request, so use highest res data for this field
            else {
                $data_field_map->{DATA()}{$name} = 1;
            }
        }
    }

    # At this point we will have figured out if we need to adjust
    # the start/end timeframes at all and can report the actual
    # data start/ends
    $self->actual_start($start);
    $self->actual_end($end);

    log_debug("Data field mapping: ", {filter => \&Data::Dumper::Dumper,
                                       value  => $data_field_map
              });
    
    log_debug("Data histogram mapping: ", {filter => \&Data::Dumper::Dumper,
                                           value  => $data_field_hist_map
              });

    my $fetch_start = [gettimeofday];

    log_debug("Query completed in " . tv_interval($timing_start, $fetch_start) . " seconds, fetching docs...");

    my @docs;
    my %identifiers_with_data;

    log_debug("Using " . join( ", ", keys( %$data_field_map ) ) . " as data source(s)" );

    # handle each data source we'll need to query
    foreach my $data_source ( keys( %$data_field_map ) ) {

        my $collection = $database->get_collection( $data_source );

        # which field(s) are using this aggregate collection?
        my @ds_fields = keys( %{$data_field_map->{$data_source}} );

        log_debug("Getting " . join(", ", @ds_fields) . " fields from $data_source");

	# never want the _id field inside of mongo
        my %queried_names = ("_id" => 0);

        my $cursor;
        my $aggregate_interval;

        if ( $db_name ne $self->temp_database() ) {
            foreach my $field ( @ds_fields ) {
                $queried_names{$field} = 1;
            }

            # also ask for the other fields we'll want
            $queried_names{'start'} = 1;
            $queried_names{'end'} = 1;
            $queried_names{'interval'} = 1;
            $queried_names{'identifier'} = 1;

	    # are we fetching from an aggregate data source?
	    if ( $data_source ne 'data' ) {

		# determine the interval at which this data is aggreagated
                ( $aggregate_interval ) = $data_source =~ /^data_(\d+)$/;
            }

            # remap our where fields so that they only have the identifiers
            # and the time components, we don't need the rest at this stage
	    # help from http://eli.thegreenplace.net/2008/08/15/intersection-of-1d-segments
            $where_fields = {
                '$and' => [
                    {'identifier' => {'$in' => \@identifiers}},
                    {'start' => {'$lt' => $end}},
                    {'end' => {'$gt' => $start}}
                    ]
            };
        }
        # if we are querying the temp database we need to map any where fields
        # onto their symbolized values since the temp table won't know what "node"
        # is, only something like "a"
        else {
            $self->_symbolize_where($where_fields, $doc_symbols);

            # Make sure when doing a query into a temp database that we add our
            # processes ID to the where clause
            if ($where_fields && ! exists $where_fields->{'$and'}){
                $where_fields = {'$and' => [$where_fields]};
            }
            push(@{$where_fields->{'$and'}}, {'__tsds_temp_id' => $self->temp_id()});

            log_debug("Where query after being symbolized: ", {filter => \&Data::Dumper::Dumper,
                                                               value  => $where_fields});
        }

        # issue the query to retrieve the lowest res match data docs
        my $doc_count;
        my $is_over_data_doc_limit = 0;
        eval {
            if($metadata->{'data_doc_limit'}){
                $doc_count = $collection->count($where_fields);
                log_debug("got $doc_count results with a data_doc_limit of ".$metadata->{'data_doc_limit'});
                if($doc_count > $metadata->{'data_doc_limit'}){
                    $is_over_data_doc_limit = 1;
                    return;
                }
            }

            # if we're an aggregate data source we have to project out the values we don't want.
            # we need to project out b/c null data points are excluded from the results when you 
            # project in something as specific as 'values.input.avg' for example.
            # also want to exclude histograms if we haven't used percentile function since
            # they are big and expensive to fetch
            if($data_source ne DATA ){
                my %unqueried_names;
                foreach my $value (keys %{$metadata->{'values'}}){
                    # if this value didn't exist in our queried names exclude it and continue
                    if(!$queried_names{'values.'.$value}){
                        $unqueried_names{'values.'.$value} = 0;
                        next;
                    } 
                    # if it was in our queried names check if we actually need the histogram
                    if(!$data_field_hist_map->{$data_source}{'values.'.$value}){
                        $unqueried_names{'values.'.$value.'.hist'} = 0;
                    }
                }
                # now overwrite our projection in with what we've projected out
                %queried_names = %unqueried_names;
            }

	    if ( $db_name ne $self->temp_database() ) {

		# if its the data docs, use query index hint
		$cursor = $collection->find($where_fields)->hint( 'identifier_1_start_1_end_1' )->fields(\%queried_names);
	    }

	    else {

		$cursor = $collection->find($where_fields)->fields(\%queried_names);
	    }
        };
        if ( $@ ) {
            $self->error( "Error querying storage database: $@" );
            return;
        }
        if ($is_over_data_doc_limit) {
            $self->error( "Your query generated $doc_count documents which is greater than the configured limit of ".$metadata->{'data_doc_limit'}.". Either refactor your query or use limit and offset to page your results.");
            return;
        }

	log_debug("where fields = " . Dumper($where_fields));

	# ISSUE=11635 no docs found in high res, fall back to using aggregate
        if ( 0 && $data_source eq DATA && $database->name ne $self->temp_database() &&$collection->count($where_fields) == 0 ) {

            # log_warn( "No documents found in high res data source $data_source, falling back to use aggregate data! Query was \"$text_query\"" );

	    # $cursor = undef;

	    # # try highest resolution aggregate first
	    # foreach my $aggregate ( sort { $a->{'interval'} <=> $b->{'interval'} } @$aggregates ) {

	    #     next if ( !$aggregate->{'interval'} );
		
	    #     $collection = $database->get_collection( DATA . '_' . $aggregate->{'interval'} );

	    #     eval {

	    #         $doc_count = $collection->count($where_fields);

	    #         if($metadata->{'data_doc_limit'}){
	    #     	log_debug("got $doc_count results with a data_doc_limit of ".$metadata->{'data_doc_limit'});
	    #     	if($doc_count > $metadata->{'data_doc_limit'}){
	    #     	    $is_over_data_doc_limit = 1;
	    #     	    return;
	    #     	}
	    #         }

	    #         # this aggregate had docs
	    #         if ( $doc_count > 0 ) {

	    #     	$cursor = $collection->find($where_fields)->hint( 'identifier_1_start_1_end_1' )->fields(\%queried_names);
	    #         }
	    #     };

	    #     # try next aggregate
	    #     next if !$cursor;

	    #     if ( $@ ) {
	    #         $self->error( "Error querying storage database: $@" );
	    #         return;
	    #     }
	    #     if ($is_over_data_doc_limit) {
	    #         $self->error( "Your query generated $doc_count documents which is greater than the configured limit of ".$metadata->{'data_doc_limit'}.". Either refactor your query or use limit and offset to page your results.");
	    #         return;
	    #     }
	    # }
	}

        # ISSUE=10430 no docs found using this aggregate data source
        elsif ( $data_source ne DATA && $database->name ne $self->temp_database() && $collection->count($where_fields) == 0 ) {

            log_warn( "No documents found in aggregate data source $data_source, falling back to use high res data!" );

	    $cursor = undef;

            $collection = $database->get_collection( DATA );

            eval {

		$doc_count = $collection->count($where_fields);

                if($metadata->{'data_doc_limit'}){
                    log_debug("got $doc_count results with a data_doc_limit of ".$metadata->{'data_doc_limit'});
                    if($doc_count > $metadata->{'data_doc_limit'}){
                        $is_over_data_doc_limit = 1;
                        return;
                    }
                }

		# high res had docs
		if ( $doc_count > 0 ) {

		    $cursor = $collection->find($where_fields)->hint( 'identifier_1_start_1_end_1' )->fields(\%queried_names);
		}
            };

            if ( $@ ) {
                $self->error( "Error querying storage database: $@" );
                return;
            }
            if ($is_over_data_doc_limit) {
                $self->error( "Your query generated $doc_count documents which is greater than the configured limit of ".$metadata->{'data_doc_limit'}.". Either refactor your query or use limit and offset to page your results.");
                return;
            }

        }

	# no data found
	if ( !$cursor ) {

            log_warn( "No documents found!" );
	    next;
	}

        # the change to 1,000 point docs seems to cause hi-res queries to time out when doing the mongo sort 
        # in the find clause on start.
        # observing this with mongodb 3.0.1 this may have been fixed in 3.0.3 should revisit later.
        # for now doing the sort perl side here...       
        while (my $doc = $cursor->next()){

            my $found_identifier = $doc->{'identifier'};
            $identifiers_with_data{$found_identifier} = 1 if ( defined($found_identifier));

            # if we're selecting from a subquery result no additional tweaking is necessary, just push
            # and move on
            if ($db_name eq $self->temp_database()){
                push(@docs, $doc);
                next;
            }

            # if we're not selecting from a subqueries result, we have to fix up the multidimensional array
            # structure that exists on disk. This will also prune out any values that weren't actually in the
            # timeframe specified but were part of the document	    
            my $fixed_docs = $self->_fix_document( base_doc => $doc,
                                                   start => $start,
                                                   end => $end,
                                                   aggregate_interval => $aggregate_interval,
                                                   meta_merge_docs => \%meta_merge_docs );

            
            foreach my $fixed_doc (@$fixed_docs){
                
                push( @docs, $fixed_doc );
            }        
        }
    }

    log_debug("All docs returned from ->next in " . tv_interval($fetch_start, [gettimeofday]) . " seconds");


    # if any of our identifiers failed to have any data we still need to include them as return results,
    # just without any data values
    foreach my $identifier (keys %meta_merge_docs){

        next if (exists $identifiers_with_data{$identifier});

	foreach my $merge_doc (@{$meta_merge_docs{$identifier}}){
	    push(@docs, $merge_doc);
	}
    }

    # go through and do final touchups on all the docs to unmap the symbols
    # and remove internal identifiers
    foreach my $doc (@docs){

        # convert internal saved symbols back into their original mappings
        foreach my $symbol (keys %$doc_symbols){
            my $remapping      = $doc_symbols->{$symbol};
            $doc->{$remapping} = $self->_find_value($symbol, $doc);

            delete $doc->{$symbol};
        }

        # remove reference to internal field stuff
        delete $doc->{'_id'};
        delete $doc->{'__tsds_temp_id'};
    }

    log_debug("Docs fetched in " . tv_interval($fetch_start, [gettimeofday]) . " seconds");
    log_info("Query generated " . @docs . " result documents");

    return \@docs;
}

sub _generate_time_clause {
    my $self  = shift;
    my $start = shift;
    my $end   = shift;
    my %args  = @_;

    my $start_name = $args{'start_name'} || 'start';
    my $end_name   = $args{'end_name'} || 'end';

    return [
	{'$and' => [{$start_name => {'$lte' => $end}},
		    {$end_name   => undef}]
	},
	{'$and' => [{$start_name => {'$lte' => $end}},
		    {$end_name => {'$gte' => $start}}]
	}
	];
}

sub _get_last_non_null_timestamp {

    my ( $self, %args ) = @_;

    my $doc = $args{'doc'};
    my $field = $args{'field'};
    my $end = $args{'end'};

    # get field name, minus the values. prefix
    ( $field ) = $field =~ /^values.(.+)$/;

    # whats the aggregate interval for this doc
    my $interval = $doc->{'interval'};

    # grab ahold of all the values in this doc for this interval and this field
    my $values = $doc->{"values_$interval"}{$field};

    return if !$values;

    # loop through them starting from the end
    my @reversed = reverse( @$values );

    foreach my $value ( @reversed ) {

	my ( $timestamp, $data ) = @$value;

	# this is newer than the end timestamp we were interested in
	next if ( $timestamp > $end );

	return $timestamp if ( defined( $data ) );
    }

    # no non-null timestamp found!
    return;
}

sub _get_best_aggregate {

    my ( $self, %args ) = @_;

    my $extent = $args{'extent'};
    my $aggregates = $args{'aggregates'};

    foreach my $aggregate ( sort { $b->{'interval'} <=> $a->{'interval'} } @$aggregates ) {

        return DATA . "_$aggregate->{'interval'}" if $aggregate->{'interval'} <= $extent;
    }

    return DATA;
}

sub _is_meta_field {

    my ( $self, $field ) = @_;

    # determine field name
    my $name = $self->_get_base_field_extent($field);

    return $name !~ /^values\./;
}

sub _get_aggregates {

    my ( $self, %args ) = @_;

    my $database = $args{'database'};

    # get all available aggregates
    my $aggregate_collection = $database->get_collection( AGGREGATE );
    my $cursor;

    eval {

	$cursor = $aggregate_collection->find( {} );
    };

    if ( $@ ) {

	$self->error( "Error querying available aggregates: $@" );
	return;
    }

    my $aggregates = [];

    while ( my $aggregate = $cursor->next() ) {

	push( @$aggregates, $aggregate );
    }

    return $aggregates;
}

sub _get_meta_limit_result {
    my $self         = shift;
    my %args         = @_;

    my $database     = $args{'database'};
    my $metadata     = $args{'metadata'};
    my $where_fields = $args{'where'};
    my $by_fields    = $args{'by'};
    my $limit        = $args{'limit'};
    my $offset       = $args{'offset'};
    my $order_fields = $args{'order'};

    my $collection  = $database->get_collection(MEASUREMENTS);

    my $limit_query = clone($where_fields);

    my $group_clause = {};

    my %unique_by;

    # only project fields we care about
    my %project_fields;    

    # make sure we only query document where that field is even set
    foreach my $field (@$by_fields){
        my @sub_by_fields;

	$project_fields{$field} = 1;

        if (ref $field eq 'ARRAY'){
            push(@sub_by_fields, $field->[0]);
            foreach my $sub_by_field (@{$field->[2]}){
                push(@sub_by_fields, $sub_by_field);
            }
        }
        else {
            push(@sub_by_fields, $field);
        }

        foreach my $by_field (@sub_by_fields){

            $unique_by{$by_field} = 1;

	    # starting in Mongo 3.4 they don't allow for dotted field
	    # names, like "circuit.name" so when we ask for it out
	    # we have to get it as circuit: {name: instead
	    # we'll have to translate back on the other side
	    my @by_pieces = split(/\./, $by_field);
	    my $last_piece = pop @by_pieces;
	    my $loc = $group_clause;
	    while (my $piece = shift @by_pieces){
	    	$loc->{$piece} ||= {};
	    	$loc = $loc->{$piece};
	    }
	    $loc->{$last_piece} = '$' . $by_field;	    

	    # Can optimize to avoid having to test for existence of
	    # identifier field, will always be there in TSDS
	    # TODO - this could be extended to required fields, but
	    # is payoff worth the extra query? We aren't currently 
	    # tracking that in this module
	    next if ($by_field eq 'identifier');

            # if the where clause already had this field in it,
            # we need to ensure our limit query contains both $exists
            # and whatever the original filter on that field was
            if (exists $limit_query->{$by_field}){
                my $new_field = [{$by_field => {'$exists' => 1}},
                                 {$by_field => $limit_query->{$by_field}}];
                
                delete $limit_query->{$by_field};
                
                if (exists $limit_query->{'$and'}){
                    push(@{$limit_query->{'$and'}}, @$new_field);
                }
                else {
                    $limit_query->{'$and'} = $new_field;
                }
            }
            # if the original where clause did not specify this field,
            # we simply need to stick in a $exists qualifier
            else {
                $limit_query->{$by_field} = {'$exists' => 1};
            }
        }
    }

    log_debug("Doing inner limit query, key is " . Dumper($by_fields) . " and query is ", {filter => \&Data::Dumper::Dumper, value  => $limit_query});


    # query
    my $limited_results;
    eval {
        # mapreduce is generally regarded as slow in the community and empirical testing
        # shows that it is generally worse off than the aggregation pipeline for
        # relatively \simple tasks

        # order is VERY important to these operations.
        # aggregate is capable of doing limit/offset but we also need to know
        # total matches, so we end up doing limit / offset ourselves later

        # Figure out which fields we might need to unwind if they are arrays
        my @unique_by_keys = keys %unique_by;
        my @unwind = $self->_get_unwind_operations($metadata, \@unique_by_keys, {});

        # If we're unwinding, we need to match the unwound documents as well
        # to ensure that we're only matching the unwound parts and not all of them
        if (@unwind > 0){
            push(@unwind, {'$match' => $limit_query});
        }

        # Default sort ordering to the "by" clause elements
        my $sort  = {'$sort'  => {'_id' => 1}};
        my $group = {'_id'    => $group_clause};
       
        # If we had explicit order by fields, use those instead
        if (@$order_fields){
            $sort = {};
            foreach my $item (@$order_fields){
                my $name  = $item->[0];
                my $dir   = $item->[1];
		
		# need this field projected to be able to sort on it
		$project_fields{$name} = 1;             
   
                if (! defined $dir || $dir  =~ /asc/i){
                    $dir = 1;
                }
                else {
                    $dir = -1;
                }

		my $projected_name = $name;
		$projected_name =~ s/\./_/;

                $group->{$projected_name} = {'$first' => '$' . $name };
                $sort->{$projected_name} = $dir;
            }

            $sort = {'$sort' => $sort};
        }

        log_debug("Inner meta sort is ", {filter => \&Data::Dumper::Dumper, value  => $sort});



        my @limit_result = $collection->aggregate([{'$match'  => $limit_query},
						   @unwind, # unwind before project because unwind is also going to re-match the existing fields to filter
						   {'$project' => \%project_fields},	       						
						   {'$facet' => {
						       'totals' => [{ '$group' => { _id => $group_clause, count => { '$sum' => 1  } } }],
						       'results' => [
							   {'$group'  => $group},
							   $sort,
							   {'$limit' => $limit + $offset},
							   {'$skip'  => $offset}
							   ]							    
						    }
						   }
						  ])->all();
	

	my $total_raw = 0;
	my $total_count = 0;
	foreach my $total_res (@{$limit_result[0]->{'totals'}}){
	    $total_count++;
	    $total_raw += $total_res->{'count'};
	}

        # keep track of how many total matched
        # vs just the ones we limit/offset'd
        $self->total($total_count);
        $self->total_raw($total_raw);

	$limited_results = $limit_result[0]->{'results'};

	# Reverse of above, we might get something back
	# like "circuit: {name: " and we want to cast that back
	# to "circuit.name: {" for use later
	foreach my $limit_res (@$limited_results){
	    my $id = $limit_res->{'_id'};
	    foreach my $key (keys %$id){
		my $str = $key;
		my $val = $id->{$key};
		if (ref($val) eq 'HASH'){
		    foreach my $key2 (keys %$val){
			$limit_res->{'_id'}{$key . '.' . $key2} = $val->{$key2};			
		    }
		    delete $limit_res->{'_id'}{$key};
		}
	    }
	}

    };

    if ($@){
        $self->error("Error during aggregation pipeline: $@");
        return;
    }

    return $limited_results;
}

sub _get_unwind_operations {
    my $self        = shift;
    my $metadata    = shift;
    my $field       = shift;
    my $seen_fields = shift;

    my @unwind;

    if (ref $field eq 'ARRAY'){
	foreach my $f (@$field){
	    @unwind = (@unwind, $self->_get_unwind_operations($metadata, $f, $seen_fields));
	}
	return @unwind;
    }

    if (ref $field eq 'HASH') {
	foreach my $f (keys %$field){
	    @unwind = (@unwind, $self->_get_unwind_operations($metadata, $f, $seen_fields));
	    @unwind = (@unwind, $self->_get_unwind_operations($metadata, $field->{$f}, $seen_fields));
	}
	return @unwind;
    }

    # looking for field.subfield
    my @pieces   = split(/\./, $field);
    my $meta_loc = $metadata->{'meta_fields'};

    for (my $i = 0; $i < @pieces; $i++){
	my $piece = $pieces[$i];

	last if (! exists $meta_loc->{$piece});
	$meta_loc = $meta_loc->{$piece};

	if(defined $meta_loc->{'array'} 
	   && $meta_loc->{'array'} eq 1){
	    
	    my $full_path = join(".", @pieces[0..$i]);
	    
	    next if (exists $seen_fields->{$full_path});
	    $seen_fields->{$full_path} = 1;
	    
	    log_debug("Adding an unwind for field $full_path due to by field $field");	    
	    push(@unwind, {'$unwind' => '$' . $full_path});
	}

	if (exists $meta_loc->{'fields'}){
	    $meta_loc = $meta_loc->{'fields'};
	}
    }

    # Make sure we're putting deeper unwinds later
    @unwind = sort( { my $count_a = () = $a->{'$unwind'} =~ /\./g;
		      my $count_b = () = $b->{'$unwind'} =~ /\./g;
		      $count_a <=> $count_b } @unwind);

    return @unwind;
}

sub _verify_where_fields{
    my $self         = shift;
    my $metadata     = shift;
    my $where_names  = shift;

    my %indexes;
    flatten_keys_hash($metadata->{'meta_fields'}, undef, \%indexes);

    $indexes{'identifier'} = 1;

    foreach my $where_name (keys %{$where_names}){
        if(!defined($indexes{$where_name})){
            return 0;
        }
    }
    return 1;
}

sub _symbolize_where {
    my $self         = shift;
    my $where_fields = shift;
    my $doc_symbols  = shift;

    if (ref $where_fields eq 'ARRAY'){
	foreach my $field (@$where_fields){
	    $self->_symbolize_where($field, $doc_symbols);
	}
    }
    elsif (ref $where_fields eq 'HASH'){
	foreach my $where_key (keys %$where_fields){
	    foreach my $symbol (keys %$doc_symbols){
		if ($doc_symbols->{$symbol} eq $where_key){
		    $where_fields->{$symbol} = $where_fields->{$where_key};
		    delete $where_fields->{$where_key};
		    last;
		}
	    }
	    $self->_symbolize_where($where_fields->{$where_key}, $doc_symbols);
	}
    }

}

sub _get_distinct_fields {
    my $self = shift;
    my %args = @_;

    my $database        = $args{'database'};
    my $collection_name = $args{'collection_name'};
    my $key             = $args{'key'};
    my $query           = $args{'query'};

    log_debug("Distinct query issued to Mongo: ", {filter => \&Data::Dumper::Dumper,
						   value  => $query});

    my $timing_start = [gettimeofday];

    my $result;
    eval {
	$result = $database->run_command(["distinct" => $collection_name,
					  "key"      => $key,
					  "query"    => $query,
					 ]);
    };
    if ($@){
	$self->error("Error querying storage database: $@");
	return;
    }

    log_debug("Distinct query completed in " . tv_interval($timing_start, [gettimeofday]) . " seconds");

    my @results;
    foreach my $value (@{$result->{'values'}}) {
	push(@results, {$key => $value}) if $value;
    }

    # mark what our total was unless we did some
    # limit offset stuff earlier
    if (! defined $self->total()){
	$self->total(scalar @results);
    }

    return \@results;
}

sub _apply_order {
    my $self    = shift;
    my $results = shift;
    my $tokens  = shift;

    foreach my $token (@$tokens){
	log_debug("Ordering by " . join(", ", @$token));
    }

    my @sorted = sort {
        my $res = 0;
        foreach my $token (@$tokens){
            my ($token_name, $token_direction) = @$token;

            my $val_a;
            my $val_b;

            if ($token_direction =~ /asc/i){
                $val_a = $a->{$token_name};
                $val_b = $b->{$token_name};
            } else {
                $val_a = $b->{$token_name};
                $val_b = $a->{$token_name};
            }

            $val_a = defined $val_a ? $val_a : "";
            $val_b = defined $val_b ? $val_b : "";

            if ( $val_a eq "" || $val_b eq "" ){
                $res = $res || ($val_a cmp $val_b);
                next;
            }

            if ( $val_a =~ /^[+-]?(\d+)?(\.\d+)?([eE][+-]\d+)?$/
                 && $val_b =~ /^[+-]?(\d+)?(\.\d+)?([eE][+-]\d+)?$/ ){

                $res = $res || ($val_a <=> $val_b);
                next;
            }

            $val_a = "\L$val_a";
            $val_b = "\L$val_b";

            $res = $res || ($val_a cmp $val_b);
        } $res;
    } @$results;

    return \@sorted;
}

sub _apply_limit_offset {
    my $self    = shift;
    my $results = shift;
    my $limit   = shift;
    my $offset  = shift;

    log_debug("Limiting to $limit offset $offset");

    my @spliced = splice(@$results, $offset, $limit);
    return \@spliced;
}

sub _apply_by {

    my ( $self, $tokens, $data, $get_fields, $by_in_time, $between_fields ) = @_;

    # We can either group one document or a set of documents, this makes
    # the later code path easier to follow
    if (ref $data ne 'ARRAY'){
	$data = [$data];
    }

    my %bucket;

    log_debug("Grouping by " . Dumper(@$tokens));

    my $group_all = $self->_get_preserve_all_fields($get_fields);

    # If there is an all(foo.bar) in the get fields we need
    # to preserve them when doing the document merges

    log_debug("Preserving all fields for ", {filter => \&Data::Dumper::Dumper,
                                             value  => $group_all});


    # figure out all the actual grouping clauses and what they mean
    my %seen;

    # If any of these group bys are doing uniqueness,
    # make sure we have the data sorted correctly so we find
    # the right occurrence
    my @sort_keys;
    foreach my $token (@$tokens){
        if (ref $token eq 'ARRAY'){
            foreach my $subtoken (@{$token->[2]}){
                push(@sort_keys, $subtoken);
            }
        }
    }
    if (@sort_keys){
        log_debug("In group by, sorting data by " . join(", ", @sort_keys) . " to ensure group by uniqueness");
        @$data = sort { 
            my $sort_res = 0;
            foreach my $key (@sort_keys){
                    $sort_res = $sort_res || ($self->_find_value($key, $a) cmp $self->_find_value($key, $b));
            }
                return $sort_res;
        } @$data;
    }    

    # Step one is to determine each document's "group_value" key, which is
    # basically just a string that is the combination of that document's
    # values for each grouping field
    for (my $i = 0; $i < @$data; $i++){

	my $doc = $data->[$i];
	my $group_value = "";

        my $keep = 1;

	foreach my $token (@$tokens){
            my $value;            
            # nothing given, group everything together
            if ($token eq DEFAULT_GROUPING){
                $value = "";
            }
            # complex by clause, have to limit to unique entries
            elsif (ref $token eq 'ARRAY'){
                my $field1   = $token->[0];
                $value       = $self->_find_value($field1, $doc) || "";
                my $uniq_val = "";
                foreach my $other_field (@{$token->[2]}){
                    $uniq_val .= $self->_find_value($other_field, $doc) || "";
                }

                # If we've already seen this unique group by before but this
                # wasn't the series we saw it in, don't use it
                $seen{$value} = $uniq_val if (! exists $seen{$value});

                if ($seen{$value} ne $uniq_val){
                    $keep = 0;
                }
            }
            # simply by clause token, just find it
            else { 
                $value = $self->_find_value($token, $doc) || "";
            }
            
            $group_value .= $value;	    
	}

	# If we're trying to group metadata by its time extents
	# let's examine that first before deciding what to keep
	if ($by_in_time && exists $bucket{$group_value}){
	    # These start at current values but will get moved as needed to adjust
	    # the extents that need filling in, as possible
	    my $current_start = $doc->{'start'};
	    my $current_end   = defined $doc->{'end'} ? $doc->{'end'} : 9999999999;

	    # Cap the time consideration to the actual query times
	    if ($current_start < $between_fields->[0]){
		$current_start = $between_fields->[0];
	    }
	    if ($current_end > $between_fields->[1]){
		$current_end = $between_fields->[1];
	    }

	    # Get all of the previously used docs in start order
	    my @sorted = sort {$a->{'start'} <=> $b->{'start'} } @{$bucket{$group_value}};

	    my $prev_end = -1;

	    for (my $j = 0; $j < @sorted; $j++){
		my $existing_doc = $sorted[$j];

		my $existing_start = $existing_doc->{'start'};
		my $existing_end   = defined $existing_doc->{'end'} ? $existing_doc->{'end'} : 9999999999;		

		if ($current_start < $existing_start && $current_start > $prev_end){		    		    
		    my $truncated = $self->_clone_truncate($doc, $current_start, $existing_start);		
		    push(@{$bucket{$group_value}}, $truncated);
		    $keep = 0; # don't need to keep the base doc since we merged in the truncated one

		    # Move our "start" pointer forwards so that if we visit the next
		    $current_start = $existing_end;
		}
		if ($current_end > $existing_end && ($j == @sorted - 1 ||
						     $current_end < $sorted[$j+1]->{'start'})){
		    my $truncated = $self->_clone_truncate($doc, $existing_end, $current_end);
		    push(@{$bucket{$group_value}}, $truncated);
		    $keep = 0;
		}

		$prev_end = $existing_end;
	    }
	}

	push(@{$bucket{$group_value}}, $doc) if ($keep);
    }

    my @result;

    # Step two is to take each bucket and condense it down into a
    # single entity
    foreach my $identifier (keys %bucket){
	my $docs = $bucket{$identifier};
        my $first;

	while (my $doc = shift @$docs){

            # Convert the "all" entries into arrays if they aren't already
            # so that they can all be represented
            foreach my $group_all_key (keys %$group_all){
                if (ref $doc->{$group_all_key} ne 'ARRAY'){
                    $doc->{$group_all_key} = [$self->_find_value($group_all_key, $doc)];
                }
            }
                
            if (! defined $first){
                $first = $doc;
                next;            
            }

	    $self->_combine_docs($first, $doc);
	}

	push(@result, $first);
    }

    log_debug("Grouping resulted in " . @result . " documents");

    return \@result;
}

# Takes a merged data/metadata document and truncates it
# to the specified time.
sub _clone_truncate {
    my $self = shift;
    my $doc = shift;
    my $new_start = shift;
    my $new_end = shift;

    $doc = clone($doc);

    $doc->{'start'} = $new_start;
    $doc->{'end'} = $new_end;

    # Find any value fields and make sure they're inside these new bounds
    foreach my $key (keys %$doc){
	my $value = $doc->{$key};

	# Fresh out of the DB it's going to be 
	# {"values": {"output": [ [], [], [] ....] } }
	if (ref $value eq 'HASH' && ($key eq 'values' || $key =~ /^values\./)){
	    foreach my $key2 (keys %$value){
		my $value2 = $value->{$key2};
		for (my $i = @$value2 - 1; $i >= 0; $i--){
		    if ($value2->[$i][0] >= $new_end || $value2->[$i][0] < $new_start){
			splice(@$value2, $i, 1);
		    }
		}

	    }
	}

	# If this was out of a subquery it may just be a straight array
	# {"values.output": [ [], [], [].... ]}
	if (ref $value eq 'ARRAY' && $value->[0] eq 'ARRAY'){
	    for (my $i = @$value - 1; $i >= 0; $i--){
		if ($value->[$i][0] >= $new_end || $value->[$i][0] < $new_start){
		    splice(@$value, $i, 1);
		}
	    }
	}
    }

    return $doc;
}

sub _combine_docs {

    my ( $self, $main_doc, $current ) = @_;

    # no more data to combine
    return if (ref $current ne 'HASH');

    foreach my $key (keys %$current){

	my $values = $current->{$key};

	# is it an array?
	if (ref $values eq 'ARRAY'){

	    foreach my $value (@$values){
		push(@{$main_doc->{$key}}, $value);
	    }
	}

	# is it a hash?
	elsif (ref $values eq 'HASH'){
	    # have we found a new key which doesn't exist in the main doc but does in the current/new doc?
	    $main_doc->{$key} = {} if (! defined $main_doc->{$key});
	    $self->_combine_docs($main_doc->{$key}, $current->{$key});
	}

	# if it's just a simple scalar, copy it forward. We basically prefer the last entry here
	# and if they want to see all they should `by` by those fields
	else {
	    $main_doc->{$key} = $current->{$key};
	}
    }
}

sub _apply_aggregation_functions {
    my $self         = shift;
    my $inner_result = shift;
    my $get_fields   = shift;
    my $with_details = shift;
    my $time_range   = shift;

    my @results;

    my $num_groups = @$inner_result;

    foreach my $original_group (@$inner_result){

	my %group_result;

	# if we're a subquery keep track of all our data so we can use it later on
	if ($with_details){
	    $group_result{'subquery'} = $original_group;
	}

	foreach my $original_get_field (@$get_fields){
	    # need to make sure we don't modify the original elements in the array
	    # if we have an inner query, so create duplicate pointers that we can
	    # change to point to other structures instead
	    my $get_field = $original_get_field;
	    my $data      = $original_group;

	    my $aggregate_result;

            my $parts = $self->_get_get_token_fields($get_field);

            # If we have something like get values.foo + values.bar
            # we need to eval those separately
            if (@$parts > 1){
                my $operator = $get_field->[1];

                # Resolve both parts and calculate their final results
                my $res_a = $self->_apply_aggregation_functions([$original_group], [[$parts->[0]]], $with_details, $time_range);
                return if (! defined $res_a);
                my $res_b = $self->_apply_aggregation_functions([$original_group], [[$parts->[1]]], $with_details, $time_range);
                return if (! defined $res_b);

                # returns something like [{foo => [1, 2, 3, 4]}]
                my $name_a = (keys %{$res_a->[0]})[0];
                my $data_a = $res_a->[0]{$name_a};

                my $name_b = (keys %{$res_b->[0]})[0];
                my $data_b = $res_b->[0]{$name_b};

                my $rename = $self->_find_rename($get_field) || "$name_a $operator $name_b";

                # Do whatever math was needed on them
                $aggregate_result = $self->_combine_results($data_a, $data_b, $operator);

                $aggregate_result = {
                    $rename => $aggregate_result
                };
            }
            else {
                my $name = $get_field->[0];

                # Is this an aggregation function? If so let's see if
                # if we need to recurse into anything else
                if (ref $name eq 'ARRAY'){
                    my $copy = clone($get_field);
                  
                    # remove old reference from front of list
                    my $copy_datum = shift @$copy;

                    $name   = $copy_datum->[0];
                    my $arg = $copy_datum->[1];

                    # If the argument to this is an aggregation function, recurse
                    # down and resolve that, then use it as the input to this one
                    if (ref $arg eq 'ARRAY'){
                        $data = $self->_apply_aggregation_functions([$original_group], [[$arg]], $with_details, $time_range);
                        return if (! defined $data);
                        $data = $data->[0];
                        
                        # remap the field from its aggregation function to its
                        # final data name from inner call
                        my $rename = (keys %$data)[0];
                        $copy_datum->[1] = $rename;
                    }

                    # Rebuild our get field after remapping or anything as needed
                    for (my $i = @$copy_datum-1; $i >= 0; $i--){
                        unshift @$copy, $copy_datum->[$i];                       
                    }

                    $get_field = $copy;
                }
               
                given ($name){

                    when (/^average$/) {
                        $aggregate_result = $self->_apply_average($get_field, $data);
                    }
                    when (/^percentile$/) {
                        $aggregate_result = $self->_apply_percentile($get_field, $data);
                    }
                    when (/^count$/) {
                        $aggregate_result = $self->_apply_count($get_field, $data);
                    }
                    when (/^min$/) {
                        $aggregate_result = $self->_apply_min($get_field, $data);
                    }
                    when (/^max$/) {
                        $aggregate_result = $self->_apply_max($get_field, $data);
                    }
                    when (/^sum$/) {
                        $aggregate_result = $self->_apply_sum($get_field, $data);
                    }
                    when (/^histogram$/) {
                        $aggregate_result = $self->_apply_histogram($get_field, $data);
                    }
                    when (/^extrapolate$/) {
                        $aggregate_result = $self->_apply_extrapolate($get_field, $data, $time_range);
                    }
                    when (/^all$/) {
                        $aggregate_result = $self->_apply_all($get_field, $data);
                    }
                    when (/^aggregate$/){
                        $aggregate_result = $self->_apply_aggregate($get_field, $data);
                    }
                    default {
                        $aggregate_result = $self->_apply_default($get_field, $data);
                    }
                }
            }        
            
	    return if (! defined $aggregate_result);
            
	    foreach my $output_field (keys %$aggregate_result){
		$group_result{$output_field} = $aggregate_result->{$output_field};
	    }
	}
        
	push(@results, \%group_result);
    }
    
    return \@results;
}


sub _apply_average {

    my ( $self, $tokens, $data ) = @_;

    log_debug("Averaging tokens: ", {filter => \&Data::Dumper::Dumper,
				     value  => $tokens});

    # average foo [math] [as bar]
    my $name   = $tokens->[1];
    my $rename = $self->_find_rename($tokens) || "average($name)";
    my ($math_symbol, $math_value) = $self->_find_math($tokens);

    my @set = $self->_find_value($name, $data);


    my %result;
    my $total = 0;
    my $count = 0;

    # figure out what the average is for all defined items
    foreach my $item (@set){
        my $value = $item;
        $value = $item->[1] if (ref $item eq 'ARRAY');

	if (defined $value && Scalar::Util::looks_like_number($value)){
	    $total += $value;
	    $count++;
	}
    }

    log_debug("Average details: total was $total and count was $count");

    my $avg = undef;

    if ($count > 0){
	$avg = $total / $count;

	if ($math_symbol){
	    $avg = $self->_apply_math($avg, $math_symbol, $math_value);
	}
    }

    return {
	$rename => $avg
    };
}

sub _apply_percentile {

    my ( $self, $tokens, $data ) = @_;

    my $name       = $tokens->[1];
    my $percentile = $tokens->[2];

    my $rename = $self->_find_rename($tokens) || "percentile($name, $percentile)";
    my ($math_symbol, $math_value) = $self->_find_math($tokens);

    my @set = $self->_find_value($name, $data);

    my @values;
    foreach my $value (@set){
        $value = $value->[1] if (ref $value eq 'ARRAY');
	push(@values, $value) if (defined $value);
    }

    my $value = $self->_calculate_percentile(\@values, $percentile);

    if ($math_symbol){
	$value = $self->_apply_math($value, $math_symbol, $math_value);
    }

    return {
	$rename => $value
    };
}

sub _apply_count {
    my $self   = shift;
    my $tokens = shift;
    my $data   = shift;

    my $name = $tokens->[1];

    my $rename = $self->_find_rename($tokens) || "count($name)";
    my ($math_symbol, $math_value) = $self->_find_math($tokens);

    my @set = $self->_find_value($name, $data);

    my $count = 0;

    foreach my $value (@set){
	# are we looking at timestamp + value tuples
	# or just something else?
        $value = $value->[1] if (ref $value eq 'ARRAY');
        $count++ if (defined $value);
    }

    if ($math_symbol){
	$count = $self->_apply_math($count, $math_symbol, $math_value);
    }

    return {
	$rename => $count
    };
}

sub _apply_min {
    my $self   = shift;
    my $tokens = shift;
    my $data   = shift;

    my $name = $tokens->[1];

    my $rename = $self->_find_rename($tokens) || "min($name)";
    my ($math_symbol, $math_value) = $self->_find_math($tokens);

    my @set = $self->_find_value($name, $data);

    my $min;

    foreach my $value (@set){
        $value = $value->[1] if (ref $value eq 'ARRAY');
	next if (! defined $value);
	if (! defined $min || $value < $min){
	    $min = $value;
	}
    }

    if ($math_symbol){
	$min = $self->_apply_math($min, $math_symbol, $math_value);
    }

    return {
	$rename => $min
    };
}

sub _apply_max {
    my $self   = shift;
    my $tokens = shift;
    my $data   = shift;

    my $name = $tokens->[1];

    my $rename = $self->_find_rename($tokens) || "max($name)";
    my ($math_symbol, $math_value) = $self->_find_math($tokens);

    my @set = $self->_find_value($name, $data);

    my $max;

    foreach my $value (@set){
        $value = $value->[1] if (ref $value eq 'ARRAY');
	next if (! defined $value);
	if (! defined $max || $value > $max){
	    $max = $value;
	}
    }

    if ($math_symbol){
	$max = $self->_apply_math($max, $math_symbol, $math_value);
    }

    return {
	$rename => $max
    };
}

sub _apply_sum {
    my $self   = shift;
    my $tokens = shift;
    my $data   = shift;

    my $name = $tokens->[1];

    my $rename = $self->_find_rename($tokens) || "sum($name)";
    my ($math_symbol, $math_value) = $self->_find_math($tokens);

    my @set = $self->_find_value($name, $data);

    my $any_defined = 0;
    my $sum = 0;

    foreach my $value (@set){
        $value = $value->[1] if (ref $value eq 'ARRAY');
	if (defined $value){
            $sum         += $value;
            $any_defined = 1;
        }
    }

    if ($any_defined && $math_symbol){
	$sum = $self->_apply_math($sum, $math_symbol, $math_value);
    }

    return {
	$rename => $any_defined ? $sum : undef
    };
}

sub _apply_aggregate {

    my ( $self, $tokens, $data ) = @_;

    my $name     = $tokens->[1];
    my $extent   = $tokens->[2];
    my $function = $tokens->[3];

    my $interval = $data->{'interval'};

    my $extra;

    my $default = "aggregate($name, $extent, $function)";
    if (ref $function eq 'ARRAY'){
	$extra    = $function->[1];
	$function = $function->[0];

	$default = "aggregate($name, $extent, $function($extra))";
    }

    my $rename = $self->_find_rename($tokens) || $default;

    my ($math_symbol, $math_value) = $self->_find_math($tokens);

    # see if we have a specific time alignement
    my $align;
    for (my $i = 0; $i < @$tokens; $i++){
	if ($tokens->[$i] eq 'align'){
	    $align = $tokens->[$i +1];
	    last;
	}
    }
    $default .= " align $align" if ($align);


    my $set = $self->_find_value( $name, $data, $extent );

    if ( !defined( $set ) || @$set == 0 ) {
	return {
	    $rename => []
	};
    }

    # adjust the extent to align/be a multiple of the data interval
    if (defined $interval){

	$extent = nlowmult( $interval, $extent ) || 1;
    }

    # map the string onto a constant to make lookups faster
    my %func_lookup = (
	'average'    => AGGREGATE_AVERAGE,
	'max'        => AGGREGATE_MAX,
	'min'        => AGGREGATE_MIN,
	'histogram'  => AGGREGATE_HIST,
	'percentile' => AGGREGATE_PERCENTILE,
	'sum'        => AGGREGATE_SUM,
	'count'      => AGGREGATE_COUNT
	);
    $function = $func_lookup{$function};

    # start all of these regardless of what function
    # we're doing to avoid reprocessing each bucket array
    my $bucket_data = {
	max       => undef,
	min       => undef,
	total     => 0,
	num_nulls => 0,
	bucket    => [],
	hists     => []
    };

    my ($extent_start, $extent_end);

    my $aggregated = [];

    @$set = sort { $a->[0] <=> $b->[0] } @$set;    

    for (my $i = 0; $i < @$set; $i++){

	my $point = $set->[$i];

	# Align the time to whatever bucket we're looking at
	my $time  = $point->[0];#int($point->[0] / $extent) * $extent;
	my $value = $point->[1];


	my $is_outside_extent = 0;

	# Is this the start of a new bucket? Data is sorted by time so 
	# we'll only see this after the last extent has finished
	if (! defined $extent_start) {
	    ($extent_start, $extent_end) = $self->__get_extent($time, $extent, $align);
	}

	# This datapoint falls outside the previous bucket, so let's wrap that bucket up
	# since we're sorted by time we know there are no more points left in it
	if ($time >= $extent_end){

	    $self->__process_bucket($aggregated, $bucket_data, $extent_start, $function, $extra);

	    # reset tracking, our current start is now the start
	    # of this data point and our accumulators are empty
	    ($extent_start, $extent_end) = $self->__get_extent($time, $extent, $align);

	    $bucket_data = {
		max       => undef,
		min       => undef,
		total     => undef,
		num_nulls => 0,
		bucket    => [],
		hists     => []
	    };
	}

	# Add current data point to our bucket tracking
	$self->__update_bucket($bucket_data, $value);
    }

    # make sure we get the last point
    $self->__process_bucket($aggregated, $bucket_data, $extent_start, $function, $extra) if (@{$bucket_data->{'bucket'}} || @{$bucket_data->{'hists'}} );

    if ($math_symbol){
	$aggregated = $self->_apply_math($aggregated, $math_symbol, $math_value);
    }

    return {
	$rename => $aggregated
    };
}

sub __get_extent {
    my $self      = shift;
    my $timestamp = shift;
    my $extent    = shift;
    my $align     = shift;

    if ($align){
	my $dt = DateTime->from_epoch(epoch => $timestamp);
	# This is a bit dangerous, but the BNF align specifications
	# match to the DateTime names
	$dt->truncate(to => $align);
	my $start_epoch = $dt->epoch();
	$dt->add($align . "s" => 1);
	return ($start_epoch, $dt->epoch());	    
    }

    my $start = int($timestamp / $extent) * $extent;
    return ($start, $start + $extent);
}

# Helper function for apply_aggregate()
sub __update_bucket {
    my $self        = shift;
    my $bucket_data = shift;  
    my $value       = shift;

    my $local_max;
    my $local_min;

    # we're looking at a retention aggregation
    if ( ref( $value ) ) {
	
	# we can be looking at either the raw histogram records or the result of a aggregate(..., histogram) result
	$local_max = $value->{'max'} if (exists $value->{'max'});
	$local_min = $value->{'min'} if (exists $value->{'min'});
	
	# 2 possibilities here - the whole thing can be the histogram such as in the case of an inner
	# query doing aggregate(....,histogram), or it might be stored under ->hist if this is the inner query.
	# TODO: would be nice to standardize this more, or add abstraction here. Seems a little hacky
	if (exists $value->{'bins'} && exists $value->{'bin_size'}){
	    push( @{$bucket_data->{'hists'}}, $value );
	}
	elsif (exists $value->{'hist'}){
	    push( @{$bucket_data->{'hists'}}, $value->{'hist'});
	}
	
	if (exists $value->{'avg'} && defined $value->{'avg'}){
	    $bucket_data->{'total'} += $value->{'avg'};
	    push( @{$bucket_data->{'bucket'}}, $value->{'avg'} );	    
	}

    }
    
    # we're looking at raw highres data
    else {
	if ( !defined( $value ) ) {
	    $bucket_data->{'num_nulls'}++;
	}
	else {
	    $local_max = $value;
	    $local_min = $value;
	    
	    $bucket_data->{'total'} += $value;
	    push(@{$bucket_data->{'bucket'}}, $value);
	}
    }

    if (defined $local_max){
	$bucket_data->{'max'} = $local_max if ( !defined( $bucket_data->{'max'} ) || $local_max > $bucket_data->{'max'} );
    }
    if (defined $local_min){
	$bucket_data->{'min'} = $local_min if ( !defined( $bucket_data->{'min'} ) || $local_min < $bucket_data->{'min'} );
    }
}

# Helper function for apply_aggregate()
sub __process_bucket {
    my $self         = shift;
    my $aggregated   = shift;
    my $bucket_data  = shift;
    my $extent_start = shift;
    my $function     = shift;
    my $extra        = shift;

    my $max       = $bucket_data->{'max'};
    my $min       = $bucket_data->{'min'};
    my $total     = $bucket_data->{'total'};
    my $num_nulls = $bucket_data->{'num_nulls'};
    my $bucket    = $bucket_data->{'bucket'};
    my $hists     = $bucket_data->{'hists'};

    # most common one, short circuit here
    if ($function == AGGREGATE_AVERAGE){
	if ( @$bucket == 0 || !defined($total) ) {	    
	    push( @$aggregated, [$extent_start, undef] );
	}		
	else {
	    push(@$aggregated, [$extent_start, $total / @$bucket]);
	}		
    }
    elsif ($function == AGGREGATE_MAX){
	push(@$aggregated, [$extent_start, $max]);
    }
    elsif ($function == AGGREGATE_MIN){
	push(@$aggregated, [$extent_start, $min]);
    }
    elsif ($function == AGGREGATE_PERCENTILE){
	my $value;
	# if we had histogram data, ie low-res data we should use those
	# to get a more accurate percentile calculation
	if (@$hists){
	    $value = $self->_calculate_percentile($bucket, $extra);
	}
	# otherwise it's based on hi-res data or no histogram available,
	# just use what we have
	else {
	    $value = $self->_calculate_percentile($bucket, $extra);
	}
	push(@$aggregated, [$extent_start, $value]);
    }
    elsif ( $function == AGGREGATE_HIST ) {
	
	foreach my $hist ( @$hists ) {
	    
	    push( @$aggregated, [$extent_start, $hist] );
	}
    }
    elsif ( $function == AGGREGATE_SUM ){
	push(@$aggregated, [$extent_start, $total]);
    }
    elsif ( $function == AGGREGATE_COUNT ) {
	push(@$aggregated, [$extent_start, scalar(@{$bucket_data->{'bucket'}})]);
    }
}


sub _apply_histogram {

    my ( $self, $tokens, $data ) = @_;

    my $name       = $tokens->[1];
    my $bin_size   = $tokens->[2];

    my $rename = $self->_find_rename($tokens) || "histogram($name, $bin_size)";

    my @set = $self->_find_value($name, $data);

    my $min;
    my $max;

    # make a first pass to find the min and max of the data set
    foreach my $point ( @set ) {

        my ( $timestamp, $value ) = @$point;

        next if ( !defined( $value ) );

        # found a new min
        $min = $value if ( !defined( $min ) || $value < $min );

        # found a new max
        $max = $value if ( !defined( $max ) || $value > $max );
    }

    my $hist;

    # only create the histogram if both a min and max were discovered
    if ( defined( $min ) && defined( $max ) ) {

        $hist = GRNOC::TSDS::Aggregate::Histogram->new( data_min => $min,
                                                        data_max => $max,
                                                        bin_size => $bin_size );

	# unable to determine histogram
	if ( !defined( $hist ) ) {

	    return {$rename => undef};
	}

	my @values;

        foreach my $point ( @set ) {

            my ( $timestamp, $value ) = @$point;

            next if ( !defined( $value ) );

	    push( @values, $value );
	}

	$hist->add_values( \@values );
    }

    return {$rename => {'total' => $hist->total(),
                        'bin_size' => $hist->bin_size(),
                        'num_bins' => $hist->num_bins(),
                        'min' => $hist->hist_min(),
                        'max' => $hist->hist_max(),
                        'bins' => $hist->bins()}};
}

sub _apply_extrapolate {
    my $self       = shift;
    my $tokens     = shift;
    my $data       = shift;
    my $time_range = shift;

    my $name        = $tokens->[1];
    my $extrapolate = $tokens->[2];

    my $rename = $self->_find_rename($tokens) || "extrapolate($name, $extrapolate)";
    my ($math_symbol, $math_value) = $self->_find_math($tokens);

    my @set = $self->_find_value($name, $data);

    my $stats = Statistics::LineFit->new();

    my @data;

    for (my $i = 0; $i < @set; $i++){
	next if (! defined $set[$i]->[1]);
	push(@data, [
		 $set[$i]->[0],
		 $set[$i]->[1]
	     ]);
    }

    $stats->setData(\@data);

    my ($intercept, $slope) = $stats->coefficients();

    log_debug("Intercept: $intercept  Slope: $slope");

    if (! defined $intercept || ! defined $slope){
	$self->error("Unable to determine slope for \"$name\"");
	return;
    }

    my $estimate;

    # now that we have the slope + intercept, simply mx+b
    # y = $slope * x + $intercept;

    # Are we asking for a timeseries?
    if ($extrapolate eq 'series'){
        my ($begin, $end);
        ($begin, $end) = @$time_range if defined($time_range);
        if (!defined($begin) || !defined($end)){
            $self->error('No time range specified for extrapolation series');
            return;
        }
        ($begin, $end) = ($end, $begin) if $end < $begin;

        # We want 20 "data points" if possible, subject to the constraint
        # that they need to have a spacing of at least 1 second:
        my $npoints = max(1, min(int($end - $begin) + 1, 20));
        my @points;

        # calculate the times of our points
        if ($npoints > 1) {
            foreach my $i (0..($npoints-1)) {
                push @points, int( (($npoints-1-$i) * $begin + $i * $end) / ($npoints-1) );
            }
        }
        else {
            push @points, int($end);
        }

        # get [time, extrapolated value] pairs
        @points = map { [$_, ($slope * $_) + $intercept] } @points;

        $estimate = \@points;
    }
    # Are we asking for what will the value be at this date?
    elsif ($extrapolate =~ /Date\((\d+)\)/){
	my $epoch = $1;
	log_debug("Determining what $name will be at $epoch");

	$estimate = ($slope * $epoch) + $intercept;
    }
    # Or are we asking for when will the value be equal to this?
    else {
	log_debug("Determining when $name will be $extrapolate");

	$estimate = int(($extrapolate - $intercept) / $slope);

	# Not needed?

	# if our estimate ended up going backwards, ie non positive slope or something
	# then consider it bad
	#if ($estimate < $end){
	#    log_warn("Unable to make future extrapolation, estimate was $estimate but end was $end");
	#    $estimate = undef;
	#}

    }

    if ($math_symbol){
	$estimate = $self->_apply_math($estimate, $math_symbol, $math_value);
    }

    return {
	$rename => $estimate
    };
}

sub _apply_all {
    my $self   = shift;
    my $tokens = shift;
    my $data   = shift;

    my $name = $tokens->[1];

    my $rename = $self->_find_rename($tokens) || "all($name)";
    my @set    = $self->_find_value($name, $data);

    my $sum = 0;

    my %seen;

    foreach my $value (@set){
        next if (! defined $value || $seen{$value});
        $seen{$value} = 1;
    }

    my @keys = keys %seen;

    return {
	$rename => \@keys
    };
}

sub _apply_default {
    my $self   = shift;
    my $tokens = shift;
    my $data   = shift;

    my $name = $tokens->[0];

    my $rename = $self->_find_rename($tokens) || "$name";
    my ($math_symbol, $math_value) = $self->_find_math($tokens);

    my $set = clone($self->_find_value($name, $data));

    if ($math_symbol){
	$set = $self->_apply_math($set, $math_symbol, $math_value);
    }

    return {
	$rename => $set
    };
}

# Take two series and merge them into a single series
# Makes the assumption that both are just an array of
# number in which case it will do a[0] $op b[0], a[1] $op b[1]...
# Or that they both arrays of [ts, val] elements in which
# case it will match them based on ts
sub _combine_results {
    my $self  = shift;
    my $res_a = shift;
    my $res_b = shift;
    my $op    = shift;

    my @result;

    # simple scalar combination, ie $x + $y
    if (! ref $res_a && ! ref $res_b){
        return $self->_apply_math($res_a, $op, $res_b);
    }

    # timeseries array combination
    # [ [0, valX1], [1, valX2].... ] + [ [0, valY1], [1, valY2] .... ]
    if (ref $res_a eq 'ARRAY' && ref $res_a->[0] eq 'ARRAY' 
     && ref $res_b eq 'ARRAY' && ref $res_b->[0] eq 'ARRAY'){
        my %lookup;

        foreach my $el (@$res_a){
            $lookup{$el->[0]} = $el->[1];
        }
        foreach my $el (@$res_b){
            my $orig = $lookup{$el->[0]} || 0;
            $lookup{$el->[0]} = $self->_apply_math($orig, $op, $el->[1]);
        }

        foreach my $ts (sort keys %lookup){
            push(@result, [$ts, $lookup{$ts}]);
        }
    }

    # array and scalar combination, can be
    # simple array or timeseries array
    # [ 1, 2, 3 ...] / 8
    elsif (ref $res_a eq 'ARRAY' && ! ref $res_b) {
	foreach my $el (@$res_a){
	    # timeseries data style array? [ [ts, val]... ]
	    if (ref $el){
		push(@result, [$el->[0],
			       $self->_apply_math($el->[1], $op, $res_b)]
		    );
	    }
	    else {
		push(@result, $self->_apply_math($el, $op, $res_b));
	    }
	} 
    }

    # basic array combination, zipper them up
    # [0, 1, 2...] + [3, 4, 5....]
    else {
        my $max = scalar(@$res_a);
        $max = scalar(@$res_b) if (scalar(@$res_b) > $max);

        for (my $i = 0; $i < $max; $i++){
            my $val_a = $res_a->[$i];
            my $val_b = $res_b->[$i];

            my $new_val = $self->_apply_math($val_a, $op, $val_b);

            push(@result, $new_val);
        }
    }

    return \@result;
}

sub _apply_math {
    my $self      = shift;
    my $values    = shift;
    my $operator  = shift;
    my $operand   = shift || "";

    log_debug("Applying math of operator: $operator operand: $operand");

    if (! $self->_is_math_symbol($operator)){
	$self->error("Unknown math symbol \"$operator\"");
	return;
    }

    if (! defined($operand) || ! Scalar::Util::looks_like_number($operand)){
	$self->error("Operand is not a number. Got \"$operand\"");
	return;
    }

    my $was_array = ref $values eq 'ARRAY';

    if (! $was_array){
	$values = [$values];
    }

    for (my $i = 0; $i < @$values; $i++){
	my $value = $values->[$i];

	# this function works on either just straight arrays of arrays of
	# arrays such as [ [$timestamp, $value], [$timestamp, $value] ... ]
	my $is_inner_array = ref $value eq 'ARRAY';

	my $original_value = $value;
	if ($is_inner_array){
	    $value = $value->[1];
	}

	if (defined $value){
	    # Use Scalar::Util looks_like_number since basic regexes are insufficient
	    # to test against very large numbers that get stringified as 1.2345e10
	    $value = undef if (! Scalar::Util::looks_like_number($value));
	}

	# undefined value?
	if ( !defined( $value ) ) {

	    if ( $is_inner_array ) {

		$values->[$i] = [$original_value->[0],
				 undef];
	    }

	    else {

		$values->[$i] = undef;
	    }

	    # skip to next point and dont do math on it
	    next;
	}


        given ($operator){
            when (/^\/$/) {
                if ($operand == 0){
                    $value = undef;
                }
                else {
                    $value = $value / $operand;
                }
            }
            when (/^\*$/) {
                $value = $value * $operand;
            }
            when (/^\+$/) {
                $value = $value + $operand;
            }
            when (/^\-$/) {
                $value = $value - $operand;
            }
        }
        

	if ($is_inner_array){
	    $values->[$i] = [$original_value->[0],
			     $value
		];
	}
	else {
	    $values->[$i] = $value;
	}
    }

    if ($was_array){
	return $values;
    }

    return $values->[0];
}

sub _find_rename {
    my $self   = shift;
    my $tokens = shift;

    for (my $i = 0; $i < @$tokens; $i++){
	if ($tokens->[$i] eq 'as'){
	    return $tokens->[$i + 1];
	}
    }

    return;
}

sub _find_math {
    my $self   = shift;
    my $tokens = shift;

    for (my $i = 0; $i < @$tokens; $i++){
	# this really should be a macro or something, it's lifted from
	# the _is_math_symbol call but faster since this is called frequently
	# to not have function overhead
	if (defined $tokens->[$i] && $tokens->[$i] =~ /^[*\/+-]$/){
	    my $math_symbol = $tokens->[$i];
	    my $math_value  = $tokens->[$i + 1];

	    return ($math_symbol, $math_value);
	}
    }

    return;
}

sub _find_value {

    my ( $self, $name, $set, $extent ) = @_;

    my @set_keys = keys( %$set );

    my $result;

    # if we already have this directly, great
    if (exists $set->{$name}){
	$result = $set->{$name};
    }
    else {

	# break up "values.output" into data => values => output
	my @words = split(/\./, $name);

	if ( defined( $extent ) ) {

	    # try to find the best aggregate extent match
	    my $best_match;

	    foreach my $set_key ( @set_keys ) {

		my ( $prefix, $suffix ) = split( /_/, $set_key );

		next if ( !defined( $prefix ) || !defined( $suffix ) );

		# did we find an exact match?
		if ( $words[0] eq $prefix && $suffix == $extent ) {

		    $best_match = $suffix;
		    last;
		}

		elsif ( $words[0] eq $prefix && $suffix < $extent ) {

		    # found a new best match
		    if ( defined( $best_match ) ) {

			$best_match = $suffix if ( $suffix > $best_match );
		    }

		    else {

			$best_match = $suffix;
		    }
		}
	    }

	    if ( $best_match ) {

		$words[0] .= "_$best_match";
	    }
	}

	foreach my $key (@words){

	    if (! exists $set->{$key}){
                log_debug("Unknown field \"$name\"");
		return;
	    }
	    $set = $set->{$key};
	}

	$result = $set;
    }

    if (wantarray()){
	if (ref $result ne 'ARRAY'){
	    my @result = ($result);
	    return @result;
	}
	return @$result;
    }

    return $result;
}


sub _fix_document {

    my ( $self, %args ) = @_;

    my $base_doc = $args{'base_doc'};
    my $query_start = $args{'start'};
    my $query_end = $args{'end'};
    my $aggregate_interval = $args{'aggregate_interval'} || undef;
    my $meta_values = $args{'meta_merge_docs'};    

    # we need to flatten out the multidimensional structure
    # and remove any points that are outside of the queried time

    my $identifier = $base_doc->{'identifier'};
    my $data_start = int($base_doc->{'start'});
    my $data_end   = int($base_doc->{'end'});
    my $interval   = int($base_doc->{'interval'});

    # merge in the measurement meta values
    my $meta_docs = $meta_values->{$identifier};

    # Calculate the leftmost start time of all the metadata docs (bound by data start)
    # and rightmost end time of all metadata docs (bound by data end)
    # An undefined value for "end" means that this is still active, so we pretend the
    # full query end is the value if so
    # First we have to prune out any metadata docs that cannot possibly receive 
    # data from this document, however and this would mess up the calculations
    my @local_meta_copies;
    foreach my $possible_meta_doc (@$meta_docs){
	next if ($possible_meta_doc->{'start'} > $data_end);
	next if (defined $possible_meta_doc->{'end'} && $possible_meta_doc->{'end'} < $data_start);
	push(@local_meta_copies, clone($possible_meta_doc));
    }

    my $earliest_meta = (sort map { $_->{'start' } } @local_meta_copies)[0];
    my $latest_meta   = (sort {$b <=> $a }
			 map { $_->{'end'} ? $_->{'end'} : $query_end } @local_meta_copies)[0];

    my $leftmost_start = $data_start;
    my $rightmost_end  = $data_end;

    if ( defined $earliest_meta ) {
        $leftmost_start = $earliest_meta if ($earliest_meta > $data_start);
    }

    if ( defined $latest_meta ) {
        $rightmost_end = $latest_meta if ($latest_meta < $data_end);
    }

    if ( !defined $leftmost_start || !defined $rightmost_end ) {
        my @empty;
        log_error( "Unable to find document(s) start-end for \$identifier: " . $meta_values->{$identifier} . " - \{ \$leftmost_start: $leftmost_start, \$rightmost_end: $rightmost_end \} - returning empty");
        return \@empty;
    }

    $leftmost_start = $earliest_meta if ($earliest_meta > $data_start);    
    $rightmost_end = $latest_meta if ($latest_meta < $data_end);

    # Unpack the data doc's arrays. This will then be segmented to the various metadata
    # docs as needed.
    my @keys = keys %{$base_doc->{'values'}};

    # We need to unpack the values from their multidimensional array 
    foreach my $measurement (@keys){
	
	my $effective_start = $data_start;
	
	my $values = $base_doc->{'values'}{$measurement};

	# See if we can scrape out unneeded parts of the packed
	# array before we have to unpack and examine everything
	# This assumes a 10x10x10 structure in the document
	my $right_splice = @$values - 1;
	my $left_splice = 0;
	for (my $i = @$values - 1; $i >= 0; $i--){
	    my $start_of_section = $data_start + ($i * $interval * 10 * 10);
	    my $end_of_section   = $data_start + (($i+1) * $interval * 10 * 10);

	    # If this entire block is earlier than the meta start, we can
	    # stop looking because we're going right to left and know we can
	    # throw this whole thing away
	    if ($end_of_section < $leftmost_start){
		$left_splice = $i + 1;
		last;
	    }
	    # If this entire block is later than the meta end, we can
	    # "decrement" our splice index to remove the unnecessary data
	    elsif ($start_of_section > $rightmost_end){
		$right_splice = $i - 1;
		next;
	    }
	    
	    # Since we're going old to new, if we haven't thrown away 
	    # the block for whatever reason we can set the start equal to it
	    $effective_start = $start_of_section;
	}
	
	my @spliced = @$values[$left_splice .. $right_splice]; 
	# now we're perl'ing with style. This unpacks the remaining
	# 3d array into a 1d flat array
	my @unpacked = map {
	    ref $_ ? map { ref $_ ? map { $_ } @$_ : $_ } @$_ : $_;
	} @spliced;


	# Now that it's unpacked, iterate through the various meta documents
	# and assign the needed blocks of data to each metadata doc
	foreach my $meta_doc (@local_meta_copies){
	    my $meta_start = $meta_doc->{'start'};
	    my $meta_end   = defined($meta_doc->{'end'}) ? $meta_doc->{'end'} : $data_end;

	    $meta_start = $data_start if ($meta_start < $data_start);
	    $meta_end = $data_end if ($meta_end > $data_end);

	    $meta_start = $query_start if ($query_start > $meta_start);
	    $meta_end   = $query_end   if ($query_end < $meta_end);

	    # Now that it's a flat array, we can strip out the exact
	    # points that don't belong in this result set. The above
	    # stripping was coarse grain - this is fine grain.
	    my $start_index = int(($meta_start - $effective_start) / $interval);
	    if ($meta_start < $effective_start){
		$start_index = 0;
	    }
	    
	    my $end_index   = int(($meta_end - $effective_start) / $interval) - 1; # non-inclusive end
	    if ($end_index > @unpacked - 1){
		$end_index = @unpacked - 1;
	    }

	    my @relevant_values = @unpacked[$start_index .. $end_index];

	    my @final_values;

	    # add timestamps to all the points now that are good
	    for (my $i = 0; $i < @relevant_values; $i++){
		push(@final_values, [$effective_start + (($start_index + $i) * $interval),
				     $relevant_values[$i]]);
	    }

	    $meta_doc->{'values'}{$measurement} = \@final_values;

	    # store aggregate data values different to avoid overlap with hires docs
	    if ( $aggregate_interval ) {
		$meta_doc->{"values_$aggregate_interval"}{$measurement} = \@final_values;
		delete( $meta_doc->{'values'}{$measurement} );
	    }
	}
    }

    foreach my $doc (@local_meta_copies){
	delete( $doc->{'values'} ) if ( keys( %{$doc->{'values'}} ) == 0 );	    
    }

    return \@local_meta_copies;
}

sub _is_aggregation_function {
    my $self = shift;
    my $word = shift;

    return 1 if ($word eq 'average' ||
		 $word eq 'percentile' ||
		 $word eq 'count' ||
		 $word eq 'min' ||
		 $word eq 'max' ||
		 $word eq 'sum' ||
		 $word eq 'histogram' ||
		 $word eq 'extrapolate' ||
                 $word eq 'all' ||
		 $word eq 'aggregate');

    return 0;
}

sub _get_base_field_extent {
    my $self      = shift;
    my $el        = shift;
    my $extent    = shift || 1;
    my $histogram = shift || 0;

    if (ref $el ne 'ARRAY'){        
        return ($el, $extent, $histogram) if (wantarray);
        return $el;
    }   

    if ($el->[0] eq 'aggregate'){
        $extent = $el->[2];

        if (ref $el->[3] eq 'ARRAY' && $el->[3][0] eq 'percentile'){
            $histogram = 1;
        }
	elsif (defined $el->[3] && $el->[3] eq 'histogram'){
	    $histogram = 1;
	}
    }

    if ($self->_is_aggregation_function($el->[0])){
        return $self->_get_base_field_extent($el->[1], $extent, $histogram);
    }
    
    return $self->_get_base_field_extent($el->[0], $extent, $histogram);
}
    
# check for field math field, ie there might be two fields in a single
# get token
sub _get_get_token_fields {
    my $self   = shift;
    my $token  = shift;

    my @parts;

    push(@parts, $token->[0]);

    if (@$token > 1 && $self->_is_math_symbol($token->[1]) && $token->[2] !~ /^(-?\d+(\.\d+)?)$/){
        push(@parts, $token->[2]);
    }

    return \@parts;
}


sub _is_math_symbol {
    my $self   = shift;
    my $symbol = shift;

    return 1 if (defined $symbol && $symbol =~ /^[*\/+-]$/);
    return 0;
}

sub _calculate_percentile {

    my ( $self, $array, $percentile ) = @_;

    # determine if we are dealing with histograms...
    my $found_hist = 0;

    foreach my $element ( @$array ) {

	# skip it if its not histogram data
	next if ( !defined( $element ) );
	next if ( !ref( $element ) );
	next if ( ref( $element ) ne 'HASH' );
	next if ( !defined( $element->{'bins'} ) );

	# found a histogram!
	$found_hist = 1;
	last;
    }

    my $value;

    # dealing with regular values
    if ( !$found_hist ) {

	my $num = @$array;

	my @sorted = sort {$a <=> $b} @$array;

	my $index = int(@sorted * ((100 - $percentile) / 100));

	$value = $sorted[@sorted - $index - 1];
    }

    # dealing with histograms
    else {

	my $aggregated_histogram = $self->_combine_histograms( $array );

	return if ( !defined( $aggregated_histogram ) );

	my $min = $aggregated_histogram->hist_min();
	my $max = $aggregated_histogram->hist_max();
	my $total = $aggregated_histogram->total();
	my $bins = $aggregated_histogram->bins();
	my $bin_size = $aggregated_histogram->bin_size();

	my $index = int( $total * ( $percentile / 100 ) );

	# decrement the counts from every in decreasing order until we find the correct bin
	my $last_bin;

	foreach my $bin_index ( sort { $b <=> $a } keys( %$bins ) ) {

	    $last_bin = $bin_index;

	    # we've found the bin for this percentile
	    last if ( $total <= $index );

	    # how many items in this bin?
	    my $count = $bins->{$bin_index};

	    $total -= $count;
	}

	# whats the midpoint / bin value of this bin
	$value = $aggregated_histogram->get_midpoint( $last_bin );
    }

    return $value;
}

sub _combine_histograms {

    my ( $self, $hists ) = @_;

    my $min;
    my $max;
    my $bin_size;

    # scan through all hists and determine the min, max, and bin size will be
    foreach my $hist ( @$hists ) {

	next if ( !defined( $hist ) );

	# found a new min
	$min = $hist->{'min'} if ( !defined( $min ) || $hist->{'min'} < $min );

	# found a new max
	$max = $hist->{'max'} if ( !defined( $max ) || $hist->{'max'} > $max );

	# found a new bin size
	$bin_size = $hist->{'bin_size'} if ( !defined( $bin_size ) || $hist->{'bin_size'} > $bin_size );
    }

    return if ( !defined( $bin_size ) );

    # create a new histogram which will contain the values from all individual histograms
    my $aggregated_hist = GRNOC::TSDS::Aggregate::Histogram->new( data_min => $min,
								  data_max => $max,
								  bin_size => $bin_size );

    # maintain cache of value => bin index
    my $index_cache = {};

    # keep track of all the bins and their counts for the new aggregated histogram
    my $bin_counts = {};

    # examine every smaller histogram that is to be aggregated into the new one
    foreach my $hist ( @$hists ) {

	my $min = $hist->{'min'};
	my $bin_size = $hist->{'bin_size'};
	my $bins = $hist->{'bins'};

	# simple optimization to avoid having to recalc indexes, if bin_size is the same
	# then index size will be same as well
	my $is_same_size = ($bin_size == $aggregated_hist->bin_size() && $min == $aggregated_hist->data_min());

	# handle every bin and its count in this histogram
	while ( my ( $bin_index, $count ) = each( %$bins ) ) {

	    # calculate the approximate data point value for this bin
	    my $value = $min + ( $bin_index * $bin_size );

	    # see if we already have a cached entry for the bin index of this value
	    my $index = $is_same_size ? $bin_index : $index_cache->{$value};

	    # determine the proper bin index of this value
	    if ( !defined( $index ) ) {
		$index = $aggregated_hist->get_index( $value );

		# cache it for later
		$index_cache->{$value} = $index;
	    }

	    # what was the prior count value for this bin
	    my $old_count = $bin_counts->{$index};

	    # had we encountered it before?
	    if ( defined( $old_count ) ) {

		$bin_counts->{$index} += $count;
	    }

	    # this is a new bin, initialize it
	    else {

		$bin_counts->{$index} = $count;
	    }
	}
    }

    # set the bins for our aggregated histogram
    $aggregated_hist->bins( $bin_counts );

    return $aggregated_hist;
}

sub _get_preserve_all_fields {
    my $self   = shift;
    my $tokens = shift;
    my $found  = shift;

    $found = {} if (! defined $found);

    return $found if (ref $tokens ne 'ARRAY');

    if ($tokens->[0] eq 'all'){

        $found->{$tokens->[1]} = 1;
        return;
    }
    
    foreach my $field (@$tokens){
        $self->_get_preserve_all_fields($field, $found);        
    }

    return $found;
}

sub update_constraints_file {

    my ( $self, $constraints_file ) = @_;

    $self->{'constraints_file'} = $constraints_file;

}

#Flatten the hash of keys of MetaData into what we need for our "where" clause
#validation... essentially pop.location.state etc...
#oh its recursive too!
sub flatten_keys_hash {
    my ($hash, $prefix, $results) = @_;

    for my $key (keys %$hash) {

        if($key eq 'fields'){

            flatten_keys_hash($hash->{$key}, $prefix, $results);
        }else{

            my $new_prefix;
            if(defined($prefix)){
                $new_prefix = "$prefix.$key";
            }else{
                $new_prefix = $key;
            }

            if (ref $hash->{$key} eq 'HASH') {
                flatten_keys_hash( $hash->{$key}, $new_prefix, $results );
            }

            $results->{$new_prefix} = 1;
        }
    }
}

1;
