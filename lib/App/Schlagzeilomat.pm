package App::Schlagzeilomat;

use Mojo::Base -base;

use Mojo::Feed;
use Mojo::SQLite;
use Mojo::WebService::Twitter;
use Mojo::File 'path';
use Mojo::JSON 'decode_json';
use Encode;
use Fcntl qw(:flock);
use Getopt::Long 'GetOptionsFromArray';
use Pod::Usage;

our $VERSION = '1.00';

has run_import  => 1;
has run_publish => 1;
has verbose     => 0;
has help        => 0;
has config      => 'schlagzeilomat.json';
has max_items   => 1;
has feeds       => sub { [] };

has access_token_secret =>
  sub { die "Missing parameter access_token_secret\n" };
has access_token => sub { die "Missing parameter access_token\n" };
has api_key      => sub { die "Missing parameter api_key\n" };
has api_secret   => sub { die "Missing parameter api_secret\n" };
has db_file      => sub { die "Missing parameter db_file\n" };

has sql => sub {
    my $self = shift;

    if ( !$self->db_file ) {
        die "$0: Missing configuration parameter db_file.\n";
    }

    my $sql = Mojo::SQLite->new->from_filename( $self->db_file );
    $sql->migrations->from_data->migrate;
    return $sql;
};

sub run {
    my ( $self, @argv ) = @_;
    my $options = {};
    GetOptionsFromArray( \@argv, $options, 'run_import|import!',
        'run_publish|publish!', 'verbose|v', 'help', 'config|c=s' )
      or pod2usage(1);

    for my $key ( keys %$options ) {
        $self->$key( $options->{$key} );
    }

    pod2usage(1) if $self->help;

    my $config_file = path( $self->config );

    if ( !-e $config_file ) {
        die "$0: Missing configuration file $config_file.\n";
    }

    open my $lock_file, '<', $config_file or die $!;
    flock $lock_file, LOCK_EX | LOCK_NB
      or die "Unable to lock file $config_file: $!\n";

    my $config = decode_json $config_file->slurp;

    for my $key ( keys %$config ) {
        if ( $self->can($key) ) {
            $self->$key( $config->{$key} );
        }
    }

    $self->import_feeds if $self->run_import;
    $self->publish      if $self->run_publish;

    return;
}

sub import_feeds {
    my $self = shift;
    for my $url ( @{ $self->feeds } ) {
        my $feed = Mojo::Feed->new( url => $url );

        for my $item ( $feed->items->reverse->each ) {
            $self->sql->db->query(
                q{ insert or ignore into items 
						(guid, title, link) values (?,?,?) },
                $item->id, $item->title, $item->link
            );
        }
    }
}

sub publish {
    my $self    = shift;
    my $db      = $self->sql->db;
    my $twitter = Mojo::WebService::Twitter->new(
        api_key    => $self->api_key,
        api_secret => $self->api_secret,
    );

    $twitter->authentication(
        oauth => $self->{access_token},
        $self->{access_token_secret},
    );

    my @items = $db->query(
'select * from items where published = 0 and skipped = 0 order by id limit ? ',
        $self->max_items
    )->hashes->each;

    for my $item (@items) {
        my $msg = $item->{title} . " " . $item->{link};
        eval { $twitter->post_tweet($msg) };
        if ($@) {
            warn $@->to_string;
            $db->update( items => { skipped => 1 }, { id => $item->{id} } );
            next;
        }
        $db->update( items => { published => 1 }, { id => $item->{id} } );
        if ( $self->verbose ) {
            warn encode( 'UTF-8', qq{Publish "$msg"\n} );
        }
    }
}

1;

__DATA__

@@ migrations

-- 2 up

alter table items add column skipped integer default 0;

-- 1 up
create table items (
	id integer primary key,
	guid text unique,
	published integer default 0,
	title text not null,
	link text not null
);

-- 1 down
drop table items;

__END__

=head1 NAME

schlagzeilomat - Publish rss feeds to twitter

=head1 SYNOPSIS

schlagzeilomat [options]

=head1 DESCRIPTION

B<schlagzeilomat> will import RSS feeds and publish it twitter. Only the
title and link will be sent. See L<https://twitter.com/taz_news> for an
example.

=head1 OPTIONS

=over

=item --[no-]publish

Publish unpublished items to twitter. [default: true]

=item --[no-]import

Import RSS feeds. [default: true]

=item --verbose

Print more information.

=item --config FILE

Set configuration file. Defaults to I<schlagzeilomat.json>.

=item --help

Show this help.

=back

=head1 CONFIGURATION FILE

The configuration must contain a valid json hash. The following keys are supported and required:

=over

=item * api_key

The bots api_key.

=item * api_secret

The bots api_secret.

=item * access_token

The accounts access token secret.

=item * access_token_secret

The accounts access token secret.

=item * db_file

The filename of the sqlite database.

=back

=head1 COPYRIGHT AND LICENSE 

Copyright 2020 Mario Domgoergen C<< <mario@domgoergen.com> >> 

This program is free software: you can redistribute it and/or modify 
it under the terms of the GNU General Public License as published by 
the Free Software Foundation, either version 3 of the License, or 
(at your option) any later version. 

This program is distributed in the hope that it will be useful, 
but WITHOUT ANY WARRANTY; without even the implied warranty of 
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the 
GNU General Public License for more details. 

You should have received a copy of the GNU General Public License 
along with this program.  If not, see <http://www.gnu.org/licenses/>. 

=cut
