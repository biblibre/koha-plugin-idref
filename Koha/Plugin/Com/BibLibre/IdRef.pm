package Koha::Plugin::Com::BibLibre::IdRef;

use Modern::Perl;

use Cwd qw(abs_path);
use LWP::UserAgent;
use JSON;
use MARC::Record;
use MARC::File::XML;

use C4::Auth qw(get_template_and_user);
use C4::AuthoritiesMarc;
use C4::Breeding;

use base 'Koha::Plugins::Base';

our $VERSION = "0.2.0";

our $metadata = {
    name            => 'IdRef',
    author          => 'BibLibre',
    date_authored   => '2021-10-20',
    date_updated    => "2021-10-20",
    minimum_version => '20.11',
    maximum_version => undef,
    version         => $VERSION,
    description     => "Permet d'importer des autorités depuis IdRef",
};

sub new {
    my ( $class, $args ) = @_;

    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    my $self = $class->SUPER::new($args);

    return $self;
}

# Mandatory even if does nothing
sub install {
    my ( $self, $args ) = @_;

    return 1;
}

# Mandatory even if does nothing
sub upgrade {
    my ( $self, $args ) = @_;

    return 1;
}

# Mandatory even if does nothing
sub uninstall {
    my ( $self, $args ) = @_;

    return 1;
}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template({ file => 'configure.tt' });

        my $copy_001_to_009 = $self->retrieve_data('copy_001_to_009') ? 1 : 0;
        $template->param(
            copy_001_to_009 => $copy_001_to_009,
        );

        $self->output_html( $template->output() );
    }
    else {
        my $copy_001_to_009 = $cgi->param('copy-001-to-009') ? 1 : 0;
        $self->store_data(
            {
                copy_001_to_009 => $copy_001_to_009,
            }
        );
        $self->go_home();
    }
}

sub intranet_js {
    my $js = <<END_JS;
    <script>
    if (document.location.pathname === "/cgi-bin/koha/authorities/authorities-home.pl" || document.location.pathname === "/cgi-bin/koha/authorities/authorities.pl") {
        const button = document.createElement("button");
        button.classList.add("btn", "btn-default");
        button.innerHTML = '<i class="fa fa-search"></i> Importer depuis IdRef';
        button.addEventListener("click", function (ev) {
            ev.preventDefault();
            window.open("/cgi-bin/koha/plugins/run.pl?class=" + encodeURIComponent("Koha::Plugin::Com::BibLibre::IdRef") + "&method=idRefSearchForm", "idrefsearch", "width=800,height=500,location=yes,toolbar=no,scrollbars=yes,resize=yes");
        });
        const z3950button = document.querySelector('#z3950_new, #z3950submit');
        if (z3950button) {
            z3950button.insertAdjacentElement('afterend', button);
        } else {
            document.querySelector('#toolbar').insertAdjacentElement('beforeend', button);
        }
    }
</script>
END_JS

    return $js;
}

sub idRefSearchForm {
    my ( $self, $args ) = @_;

    my $cgi = $self->{'cgi'};

    my ( $template, $borrowernumber ) = get_template_and_user(
        {   template_name   => abs_path( $self->mbf_path( 'idref-search-form.tt' ) ),
            query           => $cgi,
            type            => 'intranet',
            authnotrequired => 0,
            is_plugin       => 1,
        }
    );

    my $op = $cgi->param('op');
    if ($op eq 'search') {
        my $all = $cgi->param('all') // '';
        my $recordtype = $cgi->param('recordtype') // '';
        my $page = $cgi->param('page') || 1;
        $page = int $page;

        my @q;
        if ($all) {
            push @q, sprintf('all:(%s)', escape($all));
        }
        if ($recordtype) {
            push @q, sprintf('recordtype_z:%s', escape($recordtype));
        }
        my $q = @q ? join(' AND ', @q) : '*:*';

        my $rows = 10;
        my $start = ($page - 1) * $rows;

        my $ua = LWP::UserAgent->new();
        my $response = $ua->get("https://www.idref.fr/Sru/Solr?wt=json&fl=ppn_z,affcourt_z&sort=score desc&start=$start&rows=$rows&q=$q");
        unless ($response->is_success) {
            die $response->status_line;
        }

        my $solrResponse = decode_json($response->decoded_content);
        if ($solrResponse && $solrResponse->{response} && $solrResponse->{response}->{docs}) {
            my @results = map {
                {
                    ppn => $_->{ppn_z},
                    description => $_->{affcourt_z},
                }
            } @{ $solrResponse->{response}->{docs} };
            $template->param(
                all => $all,
                recordtype => $recordtype,
                page => $page,
                results => \@results,
                search => 1,
            );

            if ($solrResponse->{response}->{numFound} > $start + $rows) {
                my $nextPage = $page + 1;
                my $nextPageUrl = "/cgi-bin/koha/plugins/run.pl?class=Koha::Plugin::Com::BibLibre::IdRef&method=idRefSearchForm&op=search&all=$all&recordtype=$recordtype&page=$nextPage";
                $template->param(nextPageUrl => $nextPageUrl);
            }

            if ($page > 1) {
                my $prevPage = $page - 1;
                my $prevPageUrl = "/cgi-bin/koha/plugins/run.pl?class=Koha::Plugin::Com::BibLibre::IdRef&method=idRefSearchForm&op=search&all=$all&recordtype=$recordtype&page=$prevPage";
                $template->param(prevPageUrl => $prevPageUrl);
            }
        }
    }

    $self->output_html( $template->output() );
}

sub showMarc {
    my ( $self, $args ) = @_;

    my $cgi = $self->{'cgi'};

    my ($template) = get_template_and_user({
        template_name   => 'catalogue/showmarc.tt',
        query           => $cgi,
        type            => 'intranet',
        authnotrequired => 0,
        is_plugin       => 1,
    });

    my $ppn = $cgi->param('ppn');
    my $record = $self->_getRecordFromIdRef($ppn);
    $template->param( MARC_FORMATTED => $record->as_formatted );
    $self->output_html( $template->output() );
}

sub importBreedingAuth {
    my ( $self, $args ) = @_;

    my $cgi = $self->{cgi};
    my $ppn = $cgi->param('ppn');
    my $record = $self->_getRecordFromIdRef($ppn);
    my $heading = C4::AuthoritiesMarc::GetAuthorizedHeading({ record => $record });
    my $authtypecode = C4::AuthoritiesMarc::GuessAuthTypeCode($record);

    my $copy_001_to_009 = $self->retrieve_data('copy_001_to_009') // 0;
    if ($copy_001_to_009) {
        my $f001 = $record->field('001');
        if ($f001) {
            my $ppn = $f001->data();
            my $f009 = $record->field('009');
            if ($f009) {
                $f009->update($ppn);
            } else {
                $f009 = MARC::Field->new('009', $ppn);
                $record->insert_fields_ordered($f009);
            }
        }
    }

    my $breedingid = C4::Breeding::ImportBreedingAuth( $record, 'IdRef', 'UTF-8', $heading );

    my $data = {
        breedingid => $breedingid,
        authtypecode => $authtypecode,
    };

    $self->output(encode_json($data), 'json');
}

sub _getRecordFromIdRef {
    my ($self, $ppn) = @_;

    my $ua = LWP::UserAgent->new();
    my $response = $ua->get("https://www.idref.fr/$ppn.xml");
    unless ($response->is_success) {
        die $response->status_line;
    }
    my $record = MARC::Record->new_from_xml($response->decoded_content, 'UTF-8', 'UNIMARCAUTH');

    return $record;
}

sub escape {
    my ($s) = @_;

    # + - && || ! ( ) { } [ ] ^ " ~ * ? : \ /
    $s =~ s/([+\-&|!(){}\[\]\^"~*?:\\\/])/\\$1/g;

    return $s;
}

1;
