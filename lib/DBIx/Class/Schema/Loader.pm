package DBIx::Class::Schema::Loader;

use strict;
use warnings;
use base qw/DBIx::Class::Schema/;
use base qw/Class::Data::Accessor/;
use Carp::Clan qw/^DBIx::Class::Schema::Loader/;
use UNIVERSAL::require;
use Class::C3;
use Scalar::Util qw/ weaken /;

# Always remember to do all digits for the version even if they're 0
# i.e. first release of 0.XX *must* be 0.XX000. This avoids fBSD ports
# brain damage and presumably various other packaging systems too
our $VERSION = '0.03004';

__PACKAGE__->mk_classaccessor('dump_to_dir');
__PACKAGE__->mk_classaccessor('loader');
__PACKAGE__->mk_classaccessor('_loader_args');

=head1 NAME

DBIx::Class::Schema::Loader - Dynamic definition of a DBIx::Class::Schema

=head1 SYNOPSIS

  package My::Schema;
  use base qw/DBIx::Class::Schema::Loader/;

  __PACKAGE__->loader_options(
      relationships           => 1,
      constraint              => '^foo.*',
      # debug                 => 1,
  );

  # in seperate application code ...

  use My::Schema;

  my $schema1 = My::Schema->connect( $dsn, $user, $password, $attrs);
  # -or-
  my $schema1 = "My::Schema"; $schema1->connection(as above);

=head1 DESCRIPTION 

DBIx::Class::Schema::Loader automates the definition of a
L<DBIx::Class::Schema> by scanning database table definitions and
setting up the columns, primary keys, and relationships.

DBIx::Class::Schema::Loader currently supports only the DBI storage type.
It has explicit support for L<DBD::Pg>, L<DBD::mysql>, L<DBD::DB2>, and
L<DBD::SQLite>.  Other DBI drivers may function to a greater or lesser
degree with this loader, depending on how much of the DBI spec they
implement, and how standard their implementation is.  Patches to make
other DBDs work correctly welcome.

See L<DBIx::Class::Schema::Loader::DBI::Writing> for notes on writing
your own vendor-specific subclass for an unsupported DBD driver.

This module requires L<DBIx::Class> 0.06 or later, and obsoletes
the older L<DBIx::Class::Loader>.

This module is designed more to get you up and running quickly against
an existing database, or to be effective for simple situations, rather
than to be what you use in the long term for a complex database/project.

That being said, transitioning your code from a Schema generated by this
module to one that doesn't use this module should be straightforward and
painless (as long as you're not using any methods that are now deprecated
in this document), so don't shy away from it just for fears of the
transition down the road.

=head1 METHODS

=head2 loader_options

Example in Synopsis above demonstrates a few common arguments.  For
detailed information on all of the arguments, most of which are
only useful in fairly complex scenarios, see the
L<DBIx::Class::Schema::Loader::Base> documentation.

This method is *required* at this time, for backwards compatibility
reasons.  If you do not wish to change any options, just call it
with an empty argument list during schema class initialization.

You should either specify this method before setting the connection
information for your schema, or specify these options as a part of
your connection information (see below).  For now it will merely
warn if the ordering is wrong, but in the future this will cause problems.

=cut

sub loader_options {
    my $self = shift;
    
    my %args = (ref $_[0] eq 'HASH') ? %{$_[0]} : @_;

    my $class = ref $self || $self;
    $args{schema} = $self;
    $args{schema_class} = $class;
    weaken($args{schema}) if ref $self;

    $self->_loader_args(\%args);
    if($self->storage && !$class->loader) {
        warn "Do not set loader_options after specifying the connection info";
        $self->_invoke_loader;
    }

    $self;
}

sub _invoke_loader {
    my $self = shift;
    my $class = ref $self || $self;

    $self->_loader_args->{dump_directory} ||= $self->dump_to_dir;

    # XXX this only works for relative storage_type, like ::DBI ...
    my $impl = "DBIx::Class::Schema::Loader" . $self->storage_type;
    $impl->require or
      croak qq/Could not load storage_type loader "$impl": / .
            qq/"$UNIVERSAL::require::ERROR"/;

    # XXX in the future when we get rid of ->loader, the next two
    # lines can be replaced by "$impl->new(%{$self->_loader_args})->load;"
    $class->loader($impl->new(%{$self->_loader_args}));
    $class->loader->load;

    $self;
}

=head2 connection

See L<DBIx::Class::Schema> for basic usage.

If the final argument is a hashref, and it contains a key C<loader_options>,
that key will be deleted, and its value will be used for the loader options,
just as if set via the L</loader_options> method above.

The actual auto-loading operation (the heart of this module) will be invoked
as soon as the connection information is defined.

=cut

sub connection {
    my $self = shift;

    if($_[-1] && ref $_[-1] eq 'HASH') {
        if(my $loader_opts = delete $_[-1]->{loader_options}) {
            $self->loader_options($loader_opts);
        }
    }

    $self = $self->next::method(@_);

    my $class = ref $self || $self;
    $self->_invoke_loader if $self->_loader_args && !$class->loader;

    return $self;
}

=head2 clone

See L<DBIx::Class::Schema>.

=cut

sub clone {
    my $self = shift;

    croak "You failed to specify the required loader_options"
        if !$self->_loader_args;

    my $clone = $self->next::method(@_);

    $clone->_loader_args($self->_loader_args);
    $clone->_loader_args->{schema} = $clone;
    weaken($clone->_loader_args->{schema});

    $clone;
}

=head2 dump_to_dir

Argument: directory name.

Calling this as a class method on either L<DBIx::Class::Schema::Loader>
or any derived schema class will cause all affected schemas to dump
manual versions of themselves to the named directory when they are
loaded.  In order to be effective, this must be set before defining a
connection on this schema class or any derived object (as the loading
happens as soon as both a connection and loader_options are set, and
only once per class).

See L<DBIx::Class::Schema::Loader::Base/dump_directory> for more
details on the dumping mechanism.

This can also be set at module import time via the import option
C<dump_to_dir:/foo/bar> to L<DBIx::Class::Schema::Loader>, where
C</foo/bar> is the target directory.

Examples:

    # My::Schema isa DBIx::Class::Schema::Loader, and has connection info
    #   hardcoded in the class itself:
    perl -MDBIx::Class::Schema::Loader=dump_to_dir:/foo/bar -MMy::Schema -e1

    # Same, but no hard-coded connection, so we must provide one:
    perl -MDBIx::Class::Schema::Loader=dump_to_dir:/foo/bar -MMy::Schema -e 'My::Schema->connection("dbi:Pg:dbname=foo", ...)'

    # Or as a class method, as long as you get it done *before* defining a
    #  connection on this schema class or any derived object:
    use My::Schema;
    My::Schema->dump_to_dir('/foo/bar');
    My::Schema->connection(........);

    # Or as a class method on the DBIx::Class::Schema::Loader itself, which affects all
    #   derived schemas
    use My::Schema;
    use My::OtherSchema;
    DBIx::Class::Schema::Loader->dump_to_dir('/foo/bar');
    My::Schema->connection(.......);
    My::OtherSchema->connection(.......);

    # Another alternative to the above:
    use DBIx::Class::Schema::Loader qw| dump_to_dir:/foo/bar |;
    use My::Schema;
    use My::OtherSchema;
    My::Schema->connection(.......);
    My::OtherSchema->connection(.......);

=cut

sub import {
    my $self = shift;
    return if !@_;
    foreach my $opt (@_) {
        if($opt =~ m{^dump_to_dir:(.*)$}) {
            $self->dump_to_dir($1)
        }
        elsif($opt eq 'make_schema_at') {
            no strict 'refs';
            my $cpkg = (caller)[0];
            *{"${cpkg}::make_schema_at"} = \&make_schema_at;
        }
    }
}

=head2 make_schema_at

This simple function allows one to create a Loader-based schema
in-memory on the fly without any on-disk class files of any
kind.  When used with the C<dump_directory> option, you can
use this to generate a rough draft manual schema from a dsn
without the intermediate step of creating a physical Loader-based
schema class.

The return value is the input class name.

This function can be exported/imported by the normal means, as
illustrated in these Examples:

    # Simple example, creates as a new class 'New::Schema::Name' in
    #  memory in the running perl interpreter.
    use DBIx::Class::Schema::Loader qw/ make_schema_at /;
    make_schema_at(
        'New::Schema::Name',
        { relationships => 1, debug => 1 },
        [ 'dbi:Pg:dbname="foo"','postgres' ],
    );

    # Complex: dump loaded schema to disk, all from the commandline:
    perl -MDBIx::Class::Schema::Loader=make_schema_at,dump_to_dir:./lib -e 'make_schema_at("New::Schema::Name", { relationships => 1 }, [ "dbi:Pg:dbname=foo","postgres" ])'

    # Same, but inside a script, and using a different way to specify the
    # dump directory:
    use DBIx::Class::Schema::Loader qw/ make_schema_at /;
    make_schema_at(
        'New::Schema::Name',
        { relationships => 1, debug => 1, dump_directory => './lib' },
        [ 'dbi:Pg:dbname="foo"','postgres' ],
    );

=cut

sub make_schema_at {
    my ($target, $opts, $connect_info) = @_;

    {
        no strict 'refs';
        @{$target . '::ISA'} = qw/DBIx::Class::Schema::Loader/;
    }

    $target->loader_options($opts);
    $target->connection(@$connect_info);
}

=head1 EXAMPLE

Using the example in L<DBIx::Class::Manual::ExampleSchema> as a basis
replace the DB::Main with the following code:

  package DB::Main;

  use base qw/DBIx::Class::Schema::Loader/;

  __PACKAGE__->loader_options(
      relationships => 1,
      debug         => 1,
  );
  __PACKAGE__->connection('dbi:SQLite:example.db');

  1;

and remove the Main directory tree (optional).  Every thing else
should work the same

=head1 DEPRECATED METHODS

You don't need to read anything in this section unless you're upgrading
code that was written against pre-0.03 versions of this module.  This
version is intended to be backwards-compatible with pre-0.03 code, but
will issue warnings about your usage of deprecated features/methods.

B<All of these deprecated methods will dissappear in version 0.04000>,
and converting code that uses these methods should be trivial.

=head2 load_from_connection

This deprecated method is now roughly an alias for L</loader_options>.

For now, using this method will invoke the legacy behavior for
backwards compatibility, and merely emit a warning about upgrading
your code.

It also reverts the default inflection scheme to
use L<Lingua::EN::Inflect> just like pre-0.03 versions of this
module did.

You can force these legacy inflections with the
option L<DBIx::Class::Schema::Loader::Base/legacy_default_inflections>,
even after switch over to the preferred L</loader_options> way of doing
things.  That option will not go away until at least 0.05.

See the source of this method for more details.

=cut

sub load_from_connection {
    my ($self, %args) = @_;

    my $cmds_ver = $Catalyst::Model::DBIC::Schema::VERSION;
    if($cmds_ver) {
        if($cmds_ver < 0.14) {
            warn 'You should upgrade your installation of'
               . ' Catalyst::Model::DBIC::Schema to 0.14 or higher, then:';
        }
        warn 'You should regenerate your Model files, which may eliminate'
           . ' the following deprecation warning:';
    }
    warn 'load_from_connection deprecated, and will dissappear in 0.04000, '
       . 'please [re-]read the [new] DBIx::Class::Schema::Loader '
       . 'documentation';

    # Support the old connect_info / dsn / etc args...
    $args{connect_info} = [
        delete $args{dsn},
        delete $args{user},
        delete $args{password},
        delete $args{options},
    ] if $args{dsn};

    $self->connection(@{delete $args{connect_info}})
        if $args{connect_info};

    $self->loader_options('legacy_default_inflections' => 1, %args);
}

=head2 loader

This is an accessor in the generated Schema class for accessing
the L<DBIx::Class::Schema::Loader::Base> -based loader object
that was used during construction.  See the
L<DBIx::Class::Schema::Loader::Base> docs for more information
on the available loader methods there.

This accessor is deprecated.  Do not use it.  Anything you can
get from C<loader>, you can get via the normal L<DBIx::Class::Schema>
methods, and your code will be more robust and forward-thinking
for doing so.

If you're already using C<loader> in your code, make an effort
to get rid of it.  If you think you've found a situation where it
is necessary, let me know and we'll see what we can do to remedy
that situation.

In some future version, this accessor *will* disappear.  It was
apparently quite a design/API mistake to ever have exposed it to
user-land in the first place, all things considered.

=head1 KNOWN ISSUES

=head2 Multiple Database Schemas

Currently the loader is limited to working within a single schema
(using the database vendors' definition of "schema").  If you
have a multi-schema database with inter-schema relationships (which
is easy to do in PostgreSQL or DB2 for instance), you only get to
automatically load the tables of one schema, and any relationships
to tables in other schemas will be silently ignored.

At some point in the future, an intelligent way around this might be
devised, probably by allowing the C<db_schema> option to be an
arrayref of schemas to load.

In "normal" L<DBIx::Class::Schema> usage, manually-defined
source classes and relationships have no problems crossing vendor schemas.

=head1 AUTHOR

Brandon Black, C<blblack@gmail.com>

Based on L<DBIx::Class::Loader> by Sebastian Riedel

Based upon the work of IKEBE Tomohiro

=head1 THANK YOU

Matt S Trout, all of the #dbix-class folks, and everyone who's ever sent
in a bug report or suggestion.

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=head1 SEE ALSO

L<DBIx::Class>, L<DBIx::Class::Manual::ExampleSchema>

=cut

1;
