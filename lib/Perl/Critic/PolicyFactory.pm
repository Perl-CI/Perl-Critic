##############################################################################
#      $URL$
#     $Date$
#   $Author$
# $Revision$
##############################################################################

package Perl::Critic::PolicyFactory;

use strict;
use warnings;

use Carp qw(confess);
use English qw(-no_match_vars);

use File::Spec::Unix qw();
use List::MoreUtils qw(any);

use Perl::Critic::Utils qw{
    :characters
    $POLICY_NAMESPACE
    :data_conversion
    &policy_long_name
    :internal_lookup
};

our $VERSION = 1.04;

#-----------------------------------------------------------------------------

# Globals.  Ick!
my @SITE_POLICY_NAMES = ();

#-----------------------------------------------------------------------------

sub import {

    my ( $class, %args ) = @_;
    my $test_mode = $args{-test};

    if ( not @SITE_POLICY_NAMES ) {
        eval {
            require Module::Pluggable;
            Module::Pluggable->import(search_path => $POLICY_NAMESPACE,
                                      require => 1, inner => 0);
            @SITE_POLICY_NAMES = plugins(); #Exported by Module::Pluggable
        };

        if ( $EVAL_ERROR ) {
            confess qq{Can't load Policies from namespace "$POLICY_NAMESPACE": $EVAL_ERROR};
        }
        elsif ( ! @SITE_POLICY_NAMES ) {
            confess qq{No Policies found in namespace "$POLICY_NAMESPACE"};
        }
    }

    # In test mode, only load native policies, not third-party ones
    if ( $test_mode && any {m/\b blib \b/xms} @INC ) {
        @SITE_POLICY_NAMES = _modules_from_blib( @SITE_POLICY_NAMES );
    }

    return 1;
}

#-----------------------------------------------------------------------------
# Some static helper subs

sub _modules_from_blib {
    my (@modules) = @_;
    return grep { _was_loaded_from_blib( _module2path($_) ) } @modules;
}

sub _module2path {
    my $module = shift || return;
    return File::Spec::Unix->catdir(split m/::/xms, $module) . '.pm';
}

sub _was_loaded_from_blib {
    my $path = shift || return;
    my $full_path = $INC{$path};
    return $full_path && $full_path =~ m/\b blib \b/xms;
}

#-----------------------------------------------------------------------------

sub new {

    my ( $class, %args ) = @_;
    my $self = bless {}, $class;
    $self->_init( %args );
    return $self;
}

#-----------------------------------------------------------------------------

sub _init {

    my ($self, %args) = @_;

    $self->{_profile} = $args{-profile}
        or confess q{The -profile argument is required};

    $self->_validate_policies_in_profile();

    return $self;
}

#-----------------------------------------------------------------------------

sub create_policy {

    my ($self, %args ) = @_;

    my $policy_name = $args{-name}
        or confess q{The -name argument is required};


    # Normalize policy name to a fully-qualified package name
    $policy_name = policy_long_name( $policy_name );


    # Get the policy parameters from the user profile if they were
    # not given to us directly.  If none exist, use an empty hash.
    my $profile = $self->{_profile};
    my $policy_config = $args{-params}
        || $profile->policy_params($policy_name) || {};


    # This function will delete keys from $policy_config, so we copy them to
    # avoid modifying the callers's hash.  What a pain in the ass!
    my %policy_config_copy = $policy_config ? %{$policy_config} : ();


    # Pull out base parameters.
    my $user_set_themes = delete $policy_config_copy{set_themes};
    my $user_add_themes = delete $policy_config_copy{add_themes};
    my $user_severity   = delete $policy_config_copy{severity};

    # Instantiate parameter metadata.
    my @policy_params = eval { $policy_name->_build_parameters() };
    confess qq{Unable to create policy '$policy_name': $EVAL_ERROR} if $EVAL_ERROR;
    my %parameter_names = hashify( map { $_->get_name() } @policy_params );

    # Validate remaining parameters. This dies on failure
    $self->_validate_config_keys(
        $policy_name,
        \%parameter_names,
        \%policy_config_copy
    );

    # Construct policy from remaining params.  Trap errors.
    $policy_config_copy{__parameters} = \@policy_params;
    my $policy = eval { $policy_name->new( %policy_config_copy ) };
    confess qq{Unable to create policy '$policy_name': $EVAL_ERROR} if $EVAL_ERROR;

    # Complete initialization of the base Policy class, if the Policy subclass
    # has not already done so.
    eval { $policy->_finish_standard_initialization( \%policy_config_copy ); };
    confess qq{Unable to create policy '$policy_name': $EVAL_ERROR} if $EVAL_ERROR;

    # Set base attributes on policy
    if ( defined $user_severity ) {
        my $normalized_severity = severity_to_number( $user_severity );
        $policy->set_severity( $normalized_severity );
    }

    if ( defined $user_set_themes ) {
        my @set_themes = words_from_string( $user_set_themes );
        $policy->set_themes( @set_themes );
    }

    if ( defined $user_add_themes ) {
        my @add_themes = words_from_string( $user_add_themes );
        $policy->add_themes( @add_themes );
    }

    return $policy;
}

#-----------------------------------------------------------------------------

sub create_all_policies {

    my $self = shift;
    return map { $self->create_policy( -name => $_ ) } site_policy_names();
}

#-----------------------------------------------------------------------------

sub site_policy_names {
    return sort @SITE_POLICY_NAMES;
}

#-----------------------------------------------------------------------------

sub _validate_config_keys {
    my ($self, $policy_name, $parameter_names, $policy_config) = @_;

    my $msg = $EMPTY;

    for my $offered_param ( keys %{ $policy_config } ) {
        if ( not exists $parameter_names->{$offered_param} ) {
            $msg .= qq{Parameter "$offered_param" isn't supported by $policy_name\n};
        }
    }

    die "$msg\n" if $msg;
    return 1;
}

#-----------------------------------------------------------------------------

sub _validate_policies_in_profile {
    my ($self) = @_;

    my $profile = $self->{_profile};
    my %known_policies = hashify( $self->site_policy_names() );

    for my $policy_name ( $profile->listed_policies() ) {
        if( not exists $known_policies{$policy_name} ) {
            warn qq{Policy "$policy_name" is not installed\n};
        }
    }

    return;
}

#-----------------------------------------------------------------------------

1;

__END__


=pod

=for stopwords PolicyFactory -params

=head1 NAME

Perl::Critic::PolicyFactory - Instantiate Policy objects

=head1 DESCRIPTION

This is a helper class that instantiates L<Perl::Critic::Policy> objects with
the user's preferred parameters. There are no user-serviceable parts here.

=head1 CONSTRUCTOR

=over 8

=item C<< new( -profile => $profile >>

Returns a reference to a new Perl::Critic::PolicyFactory object.

B<-profile> is a reference to a L<Perl::Critic::UserProfile> object.  This
argument is required.

=back

=head1 METHODS

=over 8

=item C<< create_policy( -name => $policy_name, -params => \%param_hash ) >>

Creates one Policy object.  If the object cannot be instantiated, it will
throw a fatal exception.  Otherwise, it returns a reference to the new Policy
object.

B<-name> is the name of a L<Perl::Critic::Policy> subclass module.  The
C<'Perl::Critic::Policy'> portion of the name can be omitted for brevity.
This argument is required.

B<-params> is an optional reference to hash of parameters that will be passed
into the constructor of the Policy.  If C<-params> is not defined, we will use
the appropriate Policy parameters from the L<Perl::Critic::UserProfile>.

=item C< create_all_policies() >

Constructs and returns one instance of each L<Perl::Critic::Policy> subclass
that is installed on the local system.  Each Policy will be created with the
appropriate parameters from the user's configuration profile.

=back

=head1 SUBROUTINES

Perl::Critic::PolicyFactory has a few static subroutines that are used
internally, but may be useful to you in some way.

=over 8

=item C<site_policy_names()>

Returns a list of all the Policy modules that are currently installed in the
Perl::Critic:Policy namespace.  These will include modules that are
distributed with Perl::Critic plus any third-party modules that have been
installed.

=back

=head1 AUTHOR

Jeffrey Ryan Thalhammer <thaljef@cpan.org>

=head1 COPYRIGHT

Copyright (c) 2005-2007 Jeffrey Ryan Thalhammer.  All rights reserved.

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.  The full text of this license can be found in
the LICENSE file included with this module.

=cut

# Local Variables:
#   mode: cperl
#   cperl-indent-level: 4
#   fill-column: 78
#   indent-tabs-mode: nil
#   c-indentation-style: bsd
# End:
# ex: set ts=8 sts=4 sw=4 tw=78 ft=perl expandtab :
