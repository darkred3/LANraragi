package LANraragi::Model::Search;

use strict;
use warnings;
use utf8;

use List::Util qw(min);
use Redis;
use Encode;
use Storable qw/ nfreeze thaw /;
use Sort::Naturally;
use Sys::CpuAffinity;
use Parallel::Loops;
use Mojo::JSON qw(decode_json);

use LANraragi::Utils::Generic qw(split_workload_by_cpu);
use LANraragi::Utils::Database qw(redis_decode);
use LANraragi::Utils::Logging qw(get_logger);

use LANraragi::Model::Archive;
use LANraragi::Model::Category;

# do_search (filter, filter2, page, key, order, newonly, untaggedonly)
# Performs a search on the database.
sub do_search {

    my ( $filter, $categoryfilter, $start, $sortkey, $sortorder, $newonly, $untaggedonly ) = @_;

    my $redis  = LANraragi::Model::Config->get_redis;
    my $logger = get_logger( "Search Engine", "lanraragi" );

    # Search filter results
    my @filtered = ();

    # If the category filter is enabled, fetch the matching category
    my %category     = ();
    my @cat_archives = ();
    my $cat_search   = "";

    if ( $categoryfilter ne "" ) {
        %category = LANraragi::Model::Category::get_category($categoryfilter);

        if (%category) {

            # We're using a category! Update its lastused value.
            $redis->hset( $categoryfilter, "last_used", time() );

            $cat_search = $category{search};    # category search, if it's a favsearch

            if ( $cat_search eq "" ) {
                @cat_archives = @{ $category{archives} };    # category archives, if it's a standard category
            }
        }
    }

    my @keys;

    # Get all archives from redis - or just use IDs from the category if it's a standard category!
    if ( scalar @cat_archives > 0 ) {
        $logger->debug("Static category specified, using its ID list as a base instead of the entire database.");
        @keys = @cat_archives;
    } else {
        @keys = $redis->keys('????????????????????????????????????????');
    }

    # Look in searchcache first
    my $cachekey = encode_utf8("$categoryfilter-$filter-$sortkey-$sortorder-$newonly-$untaggedonly");
    $logger->debug("Search request: $cachekey");

    if ( $redis->exists("LRR_SEARCHCACHE") && $redis->hexists( "LRR_SEARCHCACHE", $cachekey ) ) {
        $logger->debug("Using cache for this query.");

        my $frozendata = $redis->hget( "LRR_SEARCHCACHE", $cachekey );
        @filtered = @{ thaw $frozendata };

    } else {

        # Setup parallel processing
        my $numCpus = Sys::CpuAffinity::getNumCpus();
        my $pl      = Parallel::Loops->new($numCpus);
        my @shared  = ();
        $pl->share( \@shared );

        $logger->debug("No cache available, doing a full DB parse.");

        # If the untagged filter is enabled, call the untagged files API
        my %untagged = ();
        if ($untaggedonly) {

            # Map the array to a hash to easily check if it contains our id
            %untagged = map { $_ => 1 } LANraragi::Model::Archive::find_untagged_archives();
        }

        my @sections = split_workload_by_cpu( $numCpus, @keys );

        # Go through tags and apply search filter in subprocesses
        $pl->foreach(
            \@sections,
            sub {

                # Get a new redis connection so we can be independent
                $redis = LANraragi::Model::Config->get_redis;
                foreach my $id (@$_) {

                    # Check untagged filter first as it requires no DB hits
                    unless ( exists( $untagged{$id} ) || !$untaggedonly ) {
                        next;
                    }

                    my %data = $redis->hgetall($id);
                    my ( $tags, $title, $file, $isnew ) = @data{qw(tags title file isnew)};
                    $title = redis_decode($title);
                    $tags  = redis_decode($tags);

                    # Check new filter first
                    if ( $newonly && $isnew && $isnew ne "true" ) {
                        next;
                    }

                    # Check category search and base search filter
                    if (   $file
                        && matches_search_filter( $cat_search, $title . "," . $tags )
                        && matches_search_filter( $filter,     $title . "," . $tags ) ) {

                        # Push id to array
                        push @shared, { id => $id, title => $title, tags => $tags };
                    }
                }
            }
        );

        # Remove the extra reference/objects Parallel::Loops adds to the array,
        # as that'll cause memory leaks when we serialize/deserialize them with Storable.
        # This is done by simply copying the parallelized array to @filtered.
        @filtered = @shared;

        if ( $#filtered > 0 ) {

            if ( !$sortkey ) {
                $sortkey = "title";
            }

            # Sort by the required metadata, asc or desc
            @filtered = sort {

                #Use either tags or title depending on the sortkey
                my $meta1 = $a->{title};
                my $meta2 = $b->{title};

                if ( $sortkey ne "title" ) {
                    my $re = qr/$sortkey/;
                    if ( $a->{tags} =~ m/.*${re}:(.*)(\,.*|$)/ ) {
                        $meta1 = $1;
                    } else {
                        $meta1 = "zzzz";    # Not a very good way to make items end at the bottom...
                    }

                    if ( $b->{tags} =~ m/.*${re}:(.*)(\,.*|$)/ ) {
                        $meta2 = $1;
                    } else {
                        $meta2 = "zzzz";
                    }
                }

                if ($sortorder) {
                    ncmp( lc($meta2), lc($meta1) );
                } else {
                    ncmp( lc($meta1), lc($meta2) );
                }

            } @filtered;
        }

        # Cache this query in Redis
        eval { $redis->hset( "LRR_SEARCHCACHE", $cachekey, nfreeze \@filtered ); };
    }
    $redis->quit();

    # Only get the first X keys
    my $keysperpage = LANraragi::Model::Config->get_pagesize;

    # Return total keys and the filtered ones
    my $end = min( $start + $keysperpage - 1, $#filtered );
    return ( $#keys + 1, $#filtered + 1, @filtered[ $start .. $end ] );
}

# matches_search_filter($filter, $tags)
# Search engine core.
sub matches_search_filter {

    my ( $filter, $tags ) = @_;
    if ( !$filter ) { $filter = ""; }

    # Special characters:
    # "" for exact search (or $ but is that one really useful)
    # ?/_ for any character
    # * % for multiple characters
    # - to exclude the next tag

    $b = reverse($filter);
    while ( $b ne "" ) {

        my $char  = chop $b;
        my $isneg = 0;

        if ( $char eq "-" ) {
            $isneg = 1;
            $char  = chop $b;
        }

        # Get characters until the next space, or the next " if the following char is "
        my $delimiter = ' ';
        if ( $char eq '"' ) {
            $delimiter = '"';
            $char      = chop $b;
        }

        my $tag     = "";
        my $isexact = 0;
      TAGBUILD: while (1) {
            if ( $char eq $delimiter || $char eq "" ) { last TAGBUILD; }
            $tag  = $tag . $char;    # Add characters in reverse order since we used reverse earlier on
            $char = chop $b;
        }

        #If last char is $, enable isexact
        if ( $delimiter eq '"' ) {
            $char = chop $b;
            if ( $char eq "\$" ) {
                $isexact = 1;
            } else {
                $b = $b . $char;
            }
        } else {
            $char = chop $tag;
            if ( $char eq "\$" ) {
                $isexact = 1;
            } else {
                $tag = $tag . $char;
            }
        }

        # Escape already present regex characters
        $tag = quotemeta($tag);

        # Replace placeholders(with an extra backslash in em thanks to quotemeta) with regex-friendly variants,
        # ? _ => .
        $tag =~ s/\\\?|\_/\./g;

        # * % => .*
        $tag =~ s/\\\*|\\\%/\.\*/g;

        # Got the tag, check if it's present
        my $tagpresent = 0;
        if ($isexact) {    # The tag must necessarily be complete if isexact = 1
             # Check for comma + potential space before and comma after the tag, or start/end of string to account for the first/last tag.
            $tagpresent = $tags =~ m/(.*\,\s*|^)$tag(\,.*|$)/i;
        } else {
            $tagpresent = $tags =~ m/.*$tag.*/i;
        }

        #present=true & isneg=true => false
        #present=false & isneg=false => false
        return 0 if ( $tagpresent == $isneg );

    }

    # All filters passed!
    return 1;
}

1;
