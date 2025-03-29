package Datastar::SSE;
use strict;
use warnings;

our $VERSION = '0.02';

use JSON ();
use JSON::Types;
use HTTP::ServerEvent;
use Scalar::Util qw/reftype/;
use PerlX::Maybe;
use Exporter qw/import unimport/;

=pod

=encoding utf-8

=head1 NAME

Datastar::SSE - INSERT YOUR ABSTRACT HERE

=head1 DESCRIPTION

Write a full description of the module and its features here.

=head1 AUTHOR

James Wright <jwright@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2025 by James Wright.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.


my %datastar_events;
my %merge_mode;
my %DATASTAR_EVENTS;
my %MERGEMODES;
BEGIN {
	%datastar_events = qw/
		merge_fragments 1
		remove_fragments 1
		merge_signals 1
		remove_signals 1
		execute_script 1
	/;
	%merge_mode = qw/
		morph 1
		inner 1
		outer 1
		prepend 1
		append 1
		before 1 
		after 1
		upsertAttributes 1
	/;
	%DATASTAR_EVENTS = +map +( "DATASTAR_\U$_" => $_ ), keys %datastar_events;
	%MERGEMODES = +map +( "MERGEMOD_\U$_" => $_ ), keys %merge_mode;
}
		
use constant { map +( "DATASTAR_\U$_", => $_ ), keys %datastar_events };
use constant { map +( "MERGEMODE_\U$_", => $_ ), keys %merge_mode };

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
	exists $datastar_events{ $event }
}

sub is_Mergemode {
	my $mode = shift or return;
	exists $merge_mode{ $mode };
}

my $headers;
sub headers {
	$headers ||= +[
		'Content-Type', 'text/event-stream',
		'Cache-Control', 'no-cache',
		'Connection', 'keep-alive',
		'Keep-Alive', 'timeout=300, max=100000'
	]
}

sub merge_signals {
	my $class = shift;
	my ($signals, $options) = @_;
	$options ||= +{
		only_if_missing => 0
	};
	my $only_if_missing = $options->{only_if_missing} || 0;
	my $event = DATASTAR_MERGE_SIGNALS;
	my @data;
	push @data, +{ onlyIfMissing => _encode_json(JSON::Types::bool $only_if_missing) };
	if (ref $signals) {
		$signals = _encode_json( $signals);
	}
	push @data, +{ signals => $signals };
	$class->_datastar_event(
		$event,
		@data
	);
}

sub execute_script {
	my $class = shift;
	my ($script, $options) = @_;
	my $event = DATASTAR_EXECUTE_SCRIPT;
	my @data;
	$script ||= [];
	return unless $script || (is_arrayref($script) && @$script);
	if (!is_arrayref($script)) {
		$script = [$script];
	}
	$options ||= +{
		auto_remove => 0,
		attributes => {},
	};
	my ($auto_remove) = $options->{auto_remove}||0;
	my %attributes = ($options->{attributes}||{})->%*;
	push @data, +{ autoRemove => _encode_json( JSON::Types::bool $auto_remove ) };
	push @data, +{ attributes => "$_ $attributes{$_}" } for keys %attributes;
	
	for (@$script) {
		my $sc = is_scalarref($_) ? $$_ : $_;
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

sub merge_fragments {
	my $class = shift;
	my ($fragment, $options) = @_;
	my $event = DATASTAR_MERGE_FRAGMENTS;
	my @data;
	$fragment ||= [];
	return unless $fragment || (is_arrayref($fragment) && @$fragment);
	if (!is_arrayref($fragment)) {
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
		if (!Int->check( $settle_duration )) {
			$settle_duration = 300;
		}
		push @data, +{ settleDuration => $settle_duration };
	}
	if (my $use_view_transition = delete $options->{use_view_transition}) {
		$use_view_transition ||= 0;
		if ($use_view_transition) {
			push @data, +{ useViewTransition => _encode_json JSON::Types::bool $use_view_transition };
		}
	}
	for (@$fragment) {
		my $frag = is_scalarref($_) ? $$_ : $_;
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

sub remove_signals {
	my $class = shift;
	my @signals = @_;
	my @data;
	my $event = DATASTAR_REMOVE_SIGNALS;
	for my $signal (@signals) {
		if ($signal && !ref( $signal)) {
			push @data, +{ paths => $signal };
		}
		if (is_arrayref($signal)) {
			push @data, +{ paths => $_ } for @$signal;
		}
	}
	$class->_datastar_event(
		$event,
		@data
	);
}

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

sub _datastar_event {
	my $class = shift;
	my ($event, @data) = @_;
	return unless $event;
	return unless is_Datastar( $event );
	my @event = ('datastar', split(/_/, $event));
	my @event_data;
	for my $data (@data) {
		push @event_data, join(' ', $data->%*);
	}
	HTTP::ServerEvent->as_string(
		event => join('-', @event ),
		data  => join("\n", @event_data),
	);
}

no PerlX::Maybe;
no Scalar::Util qw/reftype/;
1;
