use strict;
use warnings;  

use Test::More;
use Test::Exception;
use lib qw(t/lib);
use DBICTest;

{
  package DBICTest::Schema::Casecheck;

  use strict;
  use warnings;
  use base 'DBIx::Class';

  __PACKAGE__->load_components(qw/Core/);
  __PACKAGE__->table('testschema.casecheck');
  __PACKAGE__->add_columns(qw/id name NAME uc_name/);
  __PACKAGE__->column_info_from_storage(1);
  __PACKAGE__->set_primary_key('id');

}

{
  package DBICTest::Schema::ArrayTest;

  use strict;
  use warnings;
  use base 'DBIx::Class';

  __PACKAGE__->load_components(qw/Core/);
  __PACKAGE__->table('testschema.array_test');
  __PACKAGE__->add_columns(qw/id arrayfield/);
  __PACKAGE__->column_info_from_storage(1);
  __PACKAGE__->set_primary_key('id');

}

my ($dsn, $user, $pass) = @ENV{map { "DBICTEST_PG_${_}" } qw/DSN USER PASS/};

plan skip_all => 'Set $ENV{DBICTEST_PG_DSN}, _USER and _PASS to run this test '.
  '(note: This test drops and creates tables called \'artist\', \'casecheck\', \'array_test\' and \'sequence_test\''.
  ' as well as following sequences: \'pkid1_seq\', \'pkid2_seq\' and \'nonpkid_seq\''.
  ' as well as following schemas: \'testschema\'!)'
    unless ($dsn && $user);


plan tests => 37;

DBICTest::Schema->load_classes( 'Casecheck', 'ArrayTest' );
my $schema = DBICTest::Schema->connect($dsn, $user, $pass);

# Check that datetime_parser returns correctly before we explicitly connect.
SKIP: {
    eval { require DateTime::Format::Pg };
    skip "DateTime::Format::Pg required", 2 if $@;

    my $store = ref $schema->storage;
    is($store, 'DBIx::Class::Storage::DBI', 'Started with generic storage');

    my $parser = $schema->storage->datetime_parser;
    is( $parser, 'DateTime::Format::Pg', 'datetime_parser is as expected');
}

my $dbh = $schema->storage->dbh;
$schema->source("Artist")->name("testschema.artist");
$schema->source("SequenceTest")->name("testschema.sequence_test");
{
    local $SIG{__WARN__} = sub {};
    $dbh->do("CREATE SCHEMA testschema;");
    $dbh->do("CREATE TABLE testschema.artist (artistid serial PRIMARY KEY, name VARCHAR(100), rank INTEGER NOT NULL DEFAULT '13', charfield CHAR(10), arrayfield INTEGER[]);");
    $dbh->do("CREATE TABLE testschema.sequence_test (pkid1 integer, pkid2 integer, nonpkid integer, name VARCHAR(100), CONSTRAINT pk PRIMARY KEY(pkid1, pkid2));");
    $dbh->do("CREATE SEQUENCE pkid1_seq START 1 MAXVALUE 999999 MINVALUE 0");
    $dbh->do("CREATE SEQUENCE pkid2_seq START 10 MAXVALUE 999999 MINVALUE 0");
    $dbh->do("CREATE SEQUENCE nonpkid_seq START 20 MAXVALUE 999999 MINVALUE 0");
    ok ( $dbh->do('CREATE TABLE testschema.casecheck (id serial PRIMARY KEY, "name" VARCHAR(1), "NAME" VARCHAR(2), "UC_NAME" VARCHAR(3));'), 'Creation of casecheck table');
    ok ( $dbh->do('CREATE TABLE testschema.array_test (id serial PRIMARY KEY, arrayfield INTEGER[]);'), 'Creation of array_test table');
}

# This is in Core now, but it's here just to test that it doesn't break
$schema->class('Artist')->load_components('PK::Auto');

my $new = $schema->resultset('Artist')->create({ name => 'foo' });

is($new->artistid, 1, "Auto-PK worked");

$new = $schema->resultset('Artist')->create({ name => 'bar' });

is($new->artistid, 2, "Auto-PK worked");

my $test_type_info = {
    'artistid' => {
        'data_type' => 'integer',
        'is_nullable' => 0,
        'size' => 4,
    },
    'name' => {
        'data_type' => 'character varying',
        'is_nullable' => 1,
        'size' => 100,
        'default_value' => undef,
    },
    'rank' => {
        'data_type' => 'integer',
        'is_nullable' => 0,
        'size' => 4,
        'default_value' => 13,

    },
    'charfield' => {
        'data_type' => 'character',
        'is_nullable' => 1,
        'size' => 10,
        'default_value' => undef,
    },
    'arrayfield' => {
        'data_type' => 'integer[]',
        'is_nullable' => 1,
        'size' => undef,
        'default_value' => undef,
    },
};


my $type_info = $schema->storage->columns_info_for('testschema.artist');
my $artistid_defval = delete $type_info->{artistid}->{default_value};
like($artistid_defval,
     qr/^nextval\('([^\.]*\.){0,1}artist_artistid_seq'::(?:text|regclass)\)/,
     'columns_info_for - sequence matches Pg get_autoinc_seq expectations');
is_deeply($type_info, $test_type_info,
          'columns_info_for - column data types');

SKIP: {
  skip "SQL::Abstract < 1.49 does not pass through arrayrefs", 4
    if $SQL::Abstract::VERSION < 1.49;

  lives_ok {
    $schema->resultset('ArrayTest')->create({
      arrayfield => [1, 2],
    });
  } 'inserting arrayref as pg array data';

  lives_ok {
    $schema->resultset('ArrayTest')->update({
      arrayfield => [3, 4],
    });
  } 'updating arrayref as pg array data';

  $schema->resultset('ArrayTest')->create({
    arrayfield => [5, 6],
  });

  my $count;
  lives_ok {
    $count = $schema->resultset('ArrayTest')->search({
      arrayfield => \[ '= ?' => [arrayfield => [3, 4]] ],   #TODO anything less ugly than this?
    })->count;
  } 'comparing arrayref to pg array data does not blow up';
  is($count, 1, 'comparing arrayref to pg array data gives correct result');
}


my $name_info = $schema->source('Casecheck')->column_info( 'name' );
is( $name_info->{size}, 1, "Case sensitive matching info for 'name'" );

my $NAME_info = $schema->source('Casecheck')->column_info( 'NAME' );
is( $NAME_info->{size}, 2, "Case sensitive matching info for 'NAME'" );

my $uc_name_info = $schema->source('Casecheck')->column_info( 'uc_name' );
is( $uc_name_info->{size}, 3, "Case insensitive matching info for 'uc_name'" );

# Test SELECT ... FOR UPDATE
my $HaveSysSigAction = eval "require Sys::SigAction" && !$@;
if ($HaveSysSigAction) {
    Sys::SigAction->import( 'set_sig_handler' );
}

SKIP: {
    skip "Sys::SigAction is not available", 3 unless $HaveSysSigAction;
    # create a new schema
    my $schema2 = DBICTest::Schema->connect($dsn, $user, $pass);
    $schema2->source("Artist")->name("testschema.artist");

    $schema->txn_do( sub {
        my $artist = $schema->resultset('Artist')->search(
            {
                artistid => 1
            },
            {
                for => 'update'
            }
        )->first;
        is($artist->artistid, 1, "select for update returns artistid = 1");

        my $artist_from_schema2;
        my $error_ok = 0;
        eval {
            my $h = set_sig_handler( 'ALRM', sub { die "DBICTestTimeout" } );
            alarm(2);
            $artist_from_schema2 = $schema2->resultset('Artist')->find(1);
            $artist_from_schema2->name('fooey');
            $artist_from_schema2->update;
            alarm(0);
        };
        if (my $e = $@) {
            $error_ok = $e =~ /DBICTestTimeout/;
        }

        # Make sure that an error was raised, and that the update failed
        ok($error_ok, "update from second schema times out");
        ok($artist_from_schema2->is_column_changed('name'), "'name' column is still dirty from second schema");
    });
}

SKIP: {
    skip "Sys::SigAction is not available", 3 unless $HaveSysSigAction;
    # create a new schema
    my $schema2 = DBICTest::Schema->connect($dsn, $user, $pass);
    $schema2->source("Artist")->name("testschema.artist");

    $schema->txn_do( sub {
        my $artist = $schema->resultset('Artist')->search(
            {
                artistid => 1
            },
        )->first;
        is($artist->artistid, 1, "select for update returns artistid = 1");

        my $artist_from_schema2;
        my $error_ok = 0;
        eval {
            my $h = set_sig_handler( 'ALRM', sub { die "DBICTestTimeout" } );
            alarm(2);
            $artist_from_schema2 = $schema2->resultset('Artist')->find(1);
            $artist_from_schema2->name('fooey');
            $artist_from_schema2->update;
            alarm(0);
        };
        if (my $e = $@) {
            $error_ok = $e =~ /DBICTestTimeout/;
        }

        # Make sure that an error was NOT raised, and that the update succeeded
        ok(! $error_ok, "update from second schema DOES NOT timeout");
        ok(! $artist_from_schema2->is_column_changed('name'), "'name' column is NOT dirty from second schema");
    });
}

SKIP: {
  skip "Oracle Auto-PK tests are broken", 16;

  # test auto increment using sequences WITHOUT triggers
  for (1..5) {
    my $st = $schema->resultset('SequenceTest')->create({ name => 'foo' });
    is($st->pkid1, $_, "Oracle Auto-PK without trigger: First primary key");
    is($st->pkid2, $_ + 9, "Oracle Auto-PK without trigger: Second primary key");
    is($st->nonpkid, $_ + 19, "Oracle Auto-PK without trigger: Non-primary key");
  }
  my $st = $schema->resultset('SequenceTest')->create({ name => 'foo', pkid1 => 55 });
  is($st->pkid1, 55, "Oracle Auto-PK without trigger: First primary key set manually");
}

END {
    if($dbh) {
        $dbh->do("DROP TABLE testschema.artist;");
        $dbh->do("DROP TABLE testschema.casecheck;");
        $dbh->do("DROP TABLE testschema.sequence_test;");
        $dbh->do("DROP TABLE testschema.array_test;");
        $dbh->do("DROP SEQUENCE pkid1_seq");
        $dbh->do("DROP SEQUENCE pkid2_seq");
        $dbh->do("DROP SEQUENCE nonpkid_seq");
        $dbh->do("DROP SCHEMA testschema;");
    }
}

