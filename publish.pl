#!/usr/bin/env perl

use Mojolicious::Lite -signatures;
use Path::Tiny;
use Archive::Extract;
use Bytes::Random;
use Mojo::Util qw(b64_encode);
use Mojo::JSON qw(from_json to_json);

sub xdg {
    # XXX: Silence experimental warnings from File::XDG
    BEGIN {
        local %SIG;
        $SIG{__WARN__} = sub{ };
        require File::XDG;
    }
    state $xdg = File::XDG->new(name => 'mathconf')
}

sub config_file {
    path(xdg->config_home, 'publish.conf')->touchpath
}

sub tokens_file {
    path(xdg->config_home, 'tokens.json')
}

my $config = plugin Config => {file => config_file};
my $pubdir = path($config->{pubdir});
die "pubdir '$pubdir' does not exist" unless -d $pubdir->realpath;
my $admin_token = $config->{admin_token};
die "admin token must be set" unless length($admin_token);

my $registry = reload_registry;

sub reload_registry {
    -f tokens_file ? from_json(tokens_file->slurp_utf8) : +{ };
}

sub can_admin {
    my $token = shift;
    $admin_token eq $token
}

sub exists_page {
    my $key = shift;
    $registry = reload_registry;
    exists $registry->{$key}
}

sub can_access {
    my ($key, $token) = @_;
    exists $registry->{$key} and $registry->{$key} eq $token
}

sub generate_token {
    my $token = b64_encode random_bytes(48);
    chomp $token;
    $token
}

# This whole registry is horribly not concurrency-safe!
sub register_page {
    my ($key, $token) = @_;
    $registry->{$key} = $token;
    tokens_file->spew_utf8(to_json $registry);
    1
}

post '/register' => sub ($c) {
    my $page = $c->param('page');
    my $token = $c->param('token');
    if (exists_page($page)) {
        $c->render(text => "This page already exists.\n", status => 400);
        return;
    }
    if (not can_admin($token)) {
        $c->render(text => "This token is not valid for this operation.\n", status => 401);
        return;
    }
    my $new_token = generate_token;
    if (not register_page($page => $new_token)) {
        $c->render(text => "Failed to register page.\n", status => 500);
        return;
    }
    $c->render(text => "Successfully created $page! Access token: $new_token.\n");
};

post '/:page' => sub ($c) {
    my $page = $c->stash('page');
    if (not exists_page($page)) {
        $c->render(text => "The page '$page' is not registered.\n", status => 400);
        return;
    }

    my $token = $c->param('token');
    if (not $token or not can_access($page, $token)) {
        $c->render(text => "This token is not valid for the page.\n", status => 401);
        return;
    }

    my $upload = $c->req->upload('archive');
    my $file = $upload->asset->to_file;
    # For now we will simply unpack the archive into the page directory
    # without deleting anything. I'm scared of doing deletions.
    my $destdir = $pubdir->child($page);
    $destdir->mkdir;
    my $extract = Archive::Extract->new(
        archive => $file->path,
        type    => Archive::Extract::type_for($upload->filename),
    );

    my $ok = $extract->extract(to => $destdir);
    if (not $ok) {
        $c->render(text => $extract->error, status => 500);
        return;
    }
    ;
    $c->render(text => "Successfully updated $page!\n");
};

any '/*url' => {url => ''} => sub ($c) {
    my $url = $c->param('url');
    my $meth = $c->req->method;
    $c->render(text => "$meth /$url is not supported.\n", status => 404);
};

app->start;
