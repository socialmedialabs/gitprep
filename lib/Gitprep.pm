use 5.008007;
package Gitprep;

our $VERSION = '0.01';

use Mojo::Base 'Mojolicious';
use Gitprep::Git;
use DBIx::Custom;
use Validator::Custom;
use Encode qw/encode decode/;
use Mojo::JSON;
use Gitprep::API;
use Carp 'croak';
use Gitprep::RepManager;
use Scalar::Util 'weaken';
use Carp 'croak';

has 'git';
has 'dbi';
has 'validator';
has 'manager';

sub startup {
  my $self = shift;
  
  # Config
  $self->plugin('INIConfig', {ext => 'conf'});
  
  # My Config(Development)
  my $my_conf_file = $self->home->rel_file('gitprep.my.conf');
  $self->plugin('INIConfig', {file => $my_conf_file}) if -f $my_conf_file;
  
  # Config
  my $conf = $self->config;
  $conf->{hypnotoad} ||= {listen => ["http://*:10020"]};
  my $listen = $conf->{hypnotoad}{listen} || '';
  if ($listen ne '' && ref $listen ne 'ARRAY') {
    $listen = [ split /,/, $listen ];
  }
  $conf->{hypnotoad}{listen} = $listen;
  
  # Git command
  my $git = Gitprep::Git->new;
  my $git_bin = $conf->{basic}{git_bin} ? $conf->{basic}{git_bin} : $git->search_bin;
  unless ($git_bin) {
    my $error = "Can't detect git command. set git_bin in gitprep.conf";
    $self->log->error($error);
    croak $error;
  }
  unless (-e $git_bin) {
    my $error = "$git_bin is not found";
    $self->log->error($error);
    croak $error;
  }
  $git->bin($git_bin);
  
  # Repository home
  my $rep_home = $self->home->rel_file('rep');
  $git->rep_home($rep_home);
  unless (-d $rep_home) {
    mkdir $rep_home
      or croak "Can't create directory $rep_home: $!";
  }
  $self->git($git);

  # Reverse proxy support
  $ENV{MOJO_REVERSE_PROXY} = 1;
  $self->hook('before_dispatch' => sub {
    my $self = shift;
    
    if ( $self->req->headers->header('X-Forwarded-Host')) {
        my $prefix = shift @{$self->req->url->path->parts};
        push @{$self->req->url->base->path->parts}, $prefix;
    }
  });
  
  # DBI
  my $db_file = $self->home->rel_file('db/gitprep.db');
  my $dbi = DBIx::Custom->connect(
    dsn => "dbi:SQLite:database=$db_file",
    connector => 1,
    option => {sqlite_unicode => 1}
  );
  $self->dbi($dbi);

  # Create user table
  eval {
    my $sql = <<"EOS";
create table user (
  row_id integer primary key autoincrement,
  id not null unique,
  config not null
);
EOS
    $dbi->execute($sql);
  };
  
  # Create project table
  eval {
    my $sql = <<"EOS";
create table project (
  row_id integer primary key autoincrement,
  user_id not null,
  name not null,
  config not null,
  unique(user_id, name)
);
EOS
    $dbi->execute($sql);
  };
  
  # Model
  my $models = [
    {table => 'user', primary_key => 'id'},
    {table => 'project', primary_key => ['user_id', 'name']}
  ];
  $dbi->create_model($_) for @$models;

  # Fiter
  $dbi->register_filter(json => sub {
    my $value = shift;
    
    if (ref $value) {
      return decode('UTF-8', Mojo::JSON->new->encode($value));
    }
    else {
      return Mojo::JSON->new->decode(encode('UTF-8', $value));
    }
  });
  
  # Validator
  my $validator = Validator::Custom->new;
  $self->validator($validator);
  $validator->register_constraint(
    user_name => sub {
      my $value = shift;
      
      return ($value || '') =~ /^[a-zA-Z0-9_\-]+$/
    },
    project_name => sub {
      my $value = shift;
      
      return ($value || '') =~ /^[a-zA-Z0-9_\-]+$/
    }
  );
  
  # Helper
  $self->helper(gitprep_api => sub { Gitprep::API->new(shift) });
  
  # Route
  my $r = $self->routes->route->to('main#');
  
  # DBViewer(only development)
  if ($self->mode eq 'development') {
    eval {
      $self->plugin(
        'DBViewer',
        dsn => "dbi:SQLite:database=$db_file",
        route => $r
      );
    };
  }
  
  # Repository Manager
  my $manager = Gitprep::RepManager->new(app => $self);
  weaken $manager->{app};
  $self->manager($manager);

  # Home
  $r->get('/')->to('#home');
  
  # Start
  $r->any('/_start')->to('#start');
  
  # Sign in
  $r->any('/_login')->to('#login');
  
  # Admin
  $r->get('/_admin')->to('#admin');
  
  # Admin
  {
    my $r = $r->route('/_admin')->to('admin#');
    
    # Create new repository
    $r->any('/create')->to('#create');
    
    # User
    $r->any('/user')->to('#user');
  }

  # User
  $r->get('/:user')->to('#user');
  
  # Project
  {
    my $r = $r->route('/:user/:project');
    $r->get('/')->to('#project');
    
    # Commit
    $r->get('/commit/#diff')->to('#commit');
    
    # Commits
    $r->get('/commits/#rev', {id => 'HEAD'})->to('#commits');
    $r->get('/commits/#rev/(*blob)')->to('#commits');
    
    # Branches
    $r->get('/branches')->to('#branches');

    # Tags
    $r->get('/tags')->to('#tags');

    # Tree
    $r->get('/tree/(*object)')->to('#tree');
    
    # Blob
    $r->get('/blob/(*object)')->to('#blob');
    
    # Blob diff
    $r->get('/blobdiff/(#diff)/(*file)')->to('#blobdiff');
    
    # Raw
    $r->get('/raw/(*object)')->to('#raw');
    
    # Archive
    $r->get('/archive/(#rev).tar.gz')->to('#archive', archive_type => 'tar');
    $r->get('/archive/(#rev).zip')->to('#archive', archive_type => 'zip');
    
    # Compare
    $r->get('/compare/(#rev1)...(#rev2)')->to('#compare');
    
    # Settings
    $r->any('/settings')->to('#settings');
    
    # Fork
    $r->any('/fork')->to('#fork');
  }
}

1;
