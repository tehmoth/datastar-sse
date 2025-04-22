package Datastar::SSE;
use strict;
use warnings;

our $VERSION = '0.08';

use JSON ();
use HTTP::ServerEvent;
use Scalar::Util qw/reftype/;
use Exporter qw/import unimport/;

use Datastar::SSE::Types qw/is_ScalarRef is_ArrayRef is_Int/;

=pod

=encoding utf-8

=head1 NAME

Datastar::SSE - Module for creating Datastar Server Events

=head1 DESCRIPTION

An implementation of the L<< Datastar|https://data-star.dev/ >> Server Sent Event SDK in Perl

=head1 SYNOPSIS

    use Datastar::SSE -merge_modes;

	my @events;
   	push @events,  Datastar::SSE->merge_fragments( $html_fragment, +{
        selector => '#name-selector',
        merge_mode => MERGEMODE_OUTER,
    });
    # $event is a multiline string which should be sent as part of
    # the http response body.  Multiple event strings can be sent in the same response.
	for my $evt (@events) {
		$cgi->print( $evt ); # CGI
		$psgi_writer->write( $evt ); # PSGI delayed response "writer"
		$c->write( $evt ); # Mojolicious controller
	}

=cut

my @datastar_events;
my @merge_mode;
my %DATASTAR_EVENTS;
my %MERGEMODES;
BEGIN {
	my @datastar_events = qw/
		datastar_merge_fragments
		datastar_remove_fragments
		datastar_merge_signals 
		datastar_remove_signals 
		datastar_execute_script
	/;
	@merge_mode = qw/
		morph
		inner
		outer
		prepend
		append
		before 
		after
		upsertAttributes
	/;
	%DATASTAR_EVENTS = +map +( "\U$_" => s/_/-/rg ), @datastar_events;
	%MERGEMODES = +map +( "MERGEMODE_\U$_" => $_ ), @merge_mode;
}
		
use constant +{ %DATASTAR_EVENTS, %MERGEMODES };

=head1 EXPORT TAGS

The following tags can be specified to export constants related to the Datastar SSE 

=head2 -events

The L<< Datastar SSE|https://data-star.dev/reference/sse_events >> Event names:

=over

=item * DATASTAR_MERGE_FRAGMENTS

L<< datastar-merge-fragments|https://data-star.dev/reference/sse_events#datastar-merge-fragments >>

=item * DATASTAR_REMOVE_FRAGMENTS

L<< datastar-remove-fragments|https://data-star.dev/reference/sse_events#datastar-remove-fragments >>

=item * DATASTAR_MERGE_SIGNALS

L<< datastar-merge-signals|https://data-star.dev/reference/sse_events#datastar-merge-signals >>

=item * DATASTAR_REMOVE_SIGNALS

L<< datastar-remove-signals|https://data-star.dev/reference/sse_events#datastar-remove-signals >>

=item * DATASTAR_EXECUTE_SCRIPT

L<< datastar-execute-script|https://data-star.dev/reference/sse_events#datastar-execute-script >>

=back

=head2 -merge_modes

The Merge Modes for the L</merge_fragments> event:

=over

=item * MERGEMODE_MORPH

C<morph>

Merges the fragment using L<< Idiomorph|https://github.com/bigskysoftware/idiomorph >>. This is the default merge strategy.

=item * MERGEMODE_INNER

C<inner>

Replaces the target’s innerHTML with the fragment.

=item * MERGEMODE_OUTER

C<outer>

Replaces the target’s outerHTML with the fragment.

=item * MERGEMODE_PREPEND

C<prepend>

Prepends the fragment to the target’s children.

=item * MERGEMODE_APPEND

C<append>

Appends the fragment to the target’s children.

=item * MERGEMODE_BEFORE

C<before>

Inserts the fragment before the target as a sibling.

=item * MERGEMODE_AFTER

C<after>

Inserts the fragment after the target as a sibling.

=item * MERGEMODE_UPSERTATTRIBUTES

C<upsertAttributes>

Merges attributes from the fragment into the target – useful for updating a signal.

=back

=cut

our %EXPORT_TAGS = ( events => [keys(%DATASTAR_EVENTS)], merge_modes => [keys(%MERGEMODES)] );

my $json; # cache
sub _encode_json($) {
	($json  ||= JSON->new->allow_blessed->convert_blessed)->encode( @_ );
}

sub _decode_json($) {
	($json  ||= JSON->new->allow_blessed->convert_blessed)->decode( @_ );
}

sub is_Datastar {
	my $event = shift or return;
	exists $DATASTAR_EVENTS{ uc($event =~ s/-/_/rg) }
}

sub is_MergeMode {
	my $mode = shift or return;
	exists $MERGEMODES{ uc( "MERGEMODE_\U$mode" )};
}

=head1 METHODS

=head2 headers

	->headers();

Returns an Array Ref of the recommended headers to sent for Datastar SSE responses.

	Content-Type: text/event-stream
	Cache-Control: no-cache
	Connection: keep-alive
	Keep-Alive: timeout=300, max=100000

=cut

my $headers;
sub headers {
	$headers ||= +[
		'Content-Type', 'text/event-stream',
		'Cache-Control', 'no-cache',
		'Connection', 'keep-alive',
		'Keep-Alive', 'timeout=300, max=100000'
	]
}

=head1 EVENTS

=head2 merge_fragments

	->merge_fragments( $html_fragment, $options_hashref );

L<< datastar-merge-fragments|https://data-star.dev/reference/sse_events#datastar-merge-fragments >>

Merges one or more fragments into the DOM. By default, Datastar merges fragments using L<< Idiomorph|https://github.com/bigskysoftware/idiomorph >>,
which matches top level elements based on their ID.

=head3 OPTIONS

=over

=item * selector

B<Str>

Selects the target element of the merge process using a CSS selector.

=item * use_view_transition

B<Bool>

B<Default>: 0

B<Sends As>: C<useViewTransition>

Whether to use view transitions when merging into the DOM.

=item * merge_mode

B<Str|MERGEMODE>

B<Default>: MERGEMODE_MORPH

B<Sends As>: C<mergeMode>

The mode to use when merging into the DOM.

See L<< merge modes|/-merge_modes >>

=back

=cut

sub merge_fragments {
	my $class = shift;
	my ($fragment, $options) = @_;
	my $event = DATASTAR_MERGE_FRAGMENTS;
	my @data;
	$fragment ||= [];
	return unless $fragment || (is_ArrayRef($fragment) && @$fragment);
	if (!is_ArrayRef($fragment)) {
		$fragment = [$fragment];
	}

	if (my $selector = delete $options->{selector}) {
		push @data, +{ selector => $selector };
	}
	if (my $merge_mode = delete $options->{merge_mode}) {
		if (!is_MergeMode( $merge_mode )) {
			$merge_mode = MERGEMODE_MORPH;
		}
		push @data, +{ mergeMode => $merge_mode };
	}
	if (my $settle_duration = delete $options->{settle_duration}) {
		if (!is_Int( $settle_duration )) {
			$settle_duration = 300;
		}
		push @data, +{ settleDuration => $settle_duration };
	}
	if (my $use_view_transition = delete $options->{use_view_transition}) {
		$use_view_transition ||= 0;
		if ($use_view_transition) {
			push @data, +{ useViewTransition => _bool( $use_view_transition )};
		}
	}
	for (@$fragment) {
		my $frag = is_ScalarRef($_) ? $$_ : $_;
		my @frags = split /\n\r?/, $frag;
		for my $f (@frags) {
			push @data, +{ fragments => $f }
		}
	}
	$class->_datastar_event(
		$event,
		@data
	);
}

=head2 merge_signals

	->merge_signals( $signals_hashref, $options_hashref );

L<< datastar-merge-signals|https://data-star.dev/reference/sse_events#datastar-merge-signals >>

Updates the signals with new values. The only_if_missing option determines whether to update the 
signals with new values only if the key does not exist. The signals line should be a valid 
data-signals attribute. This will get merged into the signals.

=head3 OPTIONS

=over

=item * only_if_missing

B<Bool>

B<Default>: 0

B<Sends As>: C<onlyIfMissing>

Only update the signals with new values if the key does not exist.

=back

=cut

sub merge_signals {
	my $class = shift;
	my ($signals, $options) = @_;
	$options ||= +{
		only_if_missing => 0
	};
	my $only_if_missing = $options->{only_if_missing} || 0;
	my $event = DATASTAR_MERGE_SIGNALS;
	my @data;
	push @data, +{ onlyIfMissing => _bool( $only_if_missing )};
	if (ref $signals) {
		$signals = _encode_json( $signals);
	}
	push @data, +{ signals => $signals };
	$class->_datastar_event(
		$event,
		@data
	);
}

=head2 remove_fragments

	->remove_fragments( $selector )

L<< datastar-remove-fragments|https://data-star.dev/reference/sse_events#datastar-remove-fragments >>

Removes one or more HTML fragments that match the provided selector (B<$selector>) from the DOM.

=cut

sub remove_fragments {
	my $class = shift;
	my ($selector) = @_;
	return unless $selector;
	my $event = DATASTAR_REMOVE_FRAGMENTS;
	my @data = +{
		selector => $selector,
	};
	$class->_datastar_event(
		$event,
		@data
	);
}

=head2 remove_signals

	->remove_signals( @paths )

L<< datastar-remove-signals|https://data-star.dev/reference/sse_events#datastar-remove-signals >>

Removes signals that match one or more provided paths (B<@paths>).

=cut

sub remove_signals {
	my $class = shift;
	my @signals = @_;
	my @data;
	my $event = DATASTAR_REMOVE_SIGNALS;
	for my $signal (@signals) {
		if ($signal && !ref( $signal)) {
			push @data, +{ paths => $signal };
		}
		if (is_ArrayRef($signal)) {
			push @data, +{ paths => $_ } for @$signal;
		}
	}
	$class->_datastar_event(
		$event,
		@data
	);
}

=head2 execute_script

	->execute_script( $script, $options_hashref )
	->execute_script( $script_arrayref, $options_hashref )

L<< datastar-execute-script|https://data-star.dev/reference/sse_events#datastar-execute-script >>

Executes JavaScript (B<$script> or @<$script_arrayref>) in the browser. 

=head3 OPTIONS

=over

=item * auto_remove

B<Bool>

B<Default>: 0

Determines whether to remove the script elemenet after execution.

=item * attributes

B<Map[Name,Value]>

B<Default>: {}

Each attribute line adds an attribute (in the format name value) to the script element. 

=back

=cut

sub execute_script {
	my $class = shift;
	my ($script, $options) = @_;
	my $event = DATASTAR_EXECUTE_SCRIPT;
	my @data;
	$script ||= [];
	return unless $script || (is_ArrayRef($script) && @$script);
	if (!is_ArrayRef($script)) {
		$script = [$script];
	}
	$options ||= +{
		auto_remove => 0,
		attributes => {},
	};
	my ($auto_remove) = $options->{auto_remove}||0;
	my %attributes = ($options->{attributes}||{})->%*;
	push @data, +{ autoRemove => _bool( $auto_remove )};
	push @data, +{ attributes => "$_ $attributes{$_}" } for keys %attributes;
	
	for (@$script) {
		my $sc = is_ScalarRef($_) ? $$_ : $_;
		my @s = split /\n\r?/, $sc;
		for my $s (@s) {
			push @data, +{ script => $s };	
		}
	}
	$class->_datastar_event(
		$event,
		@data
	);

}




sub _datastar_event {
	my $class = shift;
	my ($event, @data) = @_;
	return unless $event;
	return unless is_Datastar( $event );
	my @event_data;
	for my $data (@data) {
		push @event_data, join(' ', $data->%*);
	}
	HTTP::ServerEvent->as_string(
		event => $event,
		data  => join("\n", @event_data),
	);
}

# 0/1 to false/true
sub _bool($) {
	shift ? "false" : "true";
}

=head1 AUTHOR

James Wright <jwright@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2025 by James Wright.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut

no JSON::Types;
no Scalar::Util; 
1;
