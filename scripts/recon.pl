#!/usr/bin/perl
=pod

=head1 NAME

LedgerSMB::Scripts::recon

=head1 SYOPSIS

This module acts as the UI controller class for Reconciliation. It controls
interfacing with the Core Logic and database layers.

=head1 METHODS

=cut

# NOTE:  This is a first draft modification to use the current parameter type.
# It will certainly need some fine tuning on my part.  Chris

package LedgerSMB::Scripts::recon;

use LedgerSMB::Template;
use LedgerSMB::DBObject::Reconciliation;

use Data::Dumper;

=pod

=over

=item display_report($self, $request, $user)

Renders out the selected report given by the incoming variable report_id.
Returns HTML, or raises an error from being unable to find the selected
report_id.

=back

=cut

sub display_report {
    my ($request) = @_;
    my $recon = LedgerSMB::DBObject::Reconciliation->new(base => $request, copy => 'all'); 
    _display_report($recon);
}

=pod

=over

=item search($self, $request, $user)

Renders out a list of meta-reports based on the search criteria passed to the
search function.
Meta-reports are report_id, date_range, and likely errors.
Search criteria accepted are 
date_begin
date_end
account
status

=back

=cut

sub update_recon_set {
    my ($request) = shift;
    my $recon = LedgerSMB::DBObject::Reconciliation->new(base => $request);
    $recon->{their_total} = $recon->parse_amount(amount => $recon->{their_total}) if defined $recon->{their_total}; 
    $recon->{dbh}->commit;
    if ($recon->{line_order}){
       $recon->set_ordering(
		{method => 'reconciliation__report_details', 
		column  => $recon->{line_order}}
       );
    }
    $recon->save() if !$recon->{submitted};
    $recon->update();
    _display_report($recon);
}

=item submit_recon_set

Submits the recon set to be approved.

=cut

sub submit_recon_set {
    my ($request) = shift;
    my $recon = LedgerSMB::DBObject::Reconciliation->new(base => $request);
    $recon->submit();
    my $template = LedgerSMB::Template->new( 
            user => $user, 
    	    template => 'reconciliation/submitted', 
    	    language => $user->{language}, 
            format => 'HTML',
            path=>"UI");
    return $template->render($recon);
    
}

=item save_recon_set

Saves the reconciliation set for later use.

=cut

sub save_recon_set {
    my ($request) = shift;
    my $recon = LedgerSMB::DBObject::Reconciliation->new(base => $request);
    if ($recon->close_form){
        $recon->save();
    } else {
        $recon->{notice} = $recon->{_locale}->text('Data not saved.  Please update again.');
    }
    my $template = LedgerSMB::Template->new( 
            user => $user, 
    	    template => 'reconciliation/search', 
    	    language => $user->{language}, 
            format => 'HTML',
            path=>"UI");
    return $template->render($recon);
    
}

=item get_results

Displays the search results

=cut

sub get_results {
    my ($request) = @_;
    $request->close_form;
    $request->open_form({commit =>1});
        if ($request->{approved} ne '1' and $request->{approved} ne '0'){
		$request->{approved} = undef;
        }
        if ($request->{submitted} ne '1' and $request->{submitted} ne '0'){
		$request->{submitted} = undef;
        }
        my $search = LedgerSMB::DBObject::Reconciliation->new(base => $request, copy => 'all');
        if ($search->{order_by}){
            $search->set_ordering({
			method => 'reconciliation__search', 
			column => $search->{order_by},
            });
        }
        my @results = $search->search();
        my @accounts = $search->get_accounts();
        my $act_hash = {};
        for my $act (@accounts){
            $act_hash->{"$act->{id}"} = $act->{name};
        }
        for my $row (@results){
            $row->{account} = $act_hash->{"$row->{chart_id}"};
        }
        my $base_url = "recon.pl?action=display_report";
        my $search_url = "recon.pl?action=get_results".
            "&date_from=$search->{date_from}&date_to=$search->{date_to}".
             "&amount_from=$search->{amount_from}&".
             "amount_to=$search->{amount_to}&chart_id=$search->{chart_id}".
             "&approved=$search->{approved}&submitted=$search->{submitted}";
        
        my $column_names = {
            "select" => 'Select',
            account => 'Account',
            their_total => 'Balance',
            end_date => 'Statement Date',
            submitted => 'Submitted',
            approved => 'Approved',
            updated => 'Last Updated',
            entered_username => 'Entered By',
            approved_username => 'Approved By'
        };
        my $sort_href = "$search_url&order_by";
        my @sort_columns = qw(account their_total end_date submitted 
            approved updated entered_username approved_username);
        
	my $cols = [];
	my @acts = $search->get_accounts;
	@$cols = qw(select account end_date their_total approved submitted 
                    updated entered_username approved_username);
	my $recon =$search;
	for my $row(@results){
            my $act = undef;
            for (@acts){
                if ($_->{id} == $row->{chart_id}){
                    $act = $_->{name};
                }
                last if $act;
            }
            $row->{account} = $act;
            $row->{their_total} = $recon->format_amount(
		{amount => $row->{their_total}, money => 1}); 
            $row->{end_date} = {
                text => $row->{end_date}, 
                href => "$base_url&report_id=$row->{id}"
            };
        }
	$recon->{_results} = \@results;
        $recon->{title} = $request->{_locale}->text('Reconciliation Sets');
        my $template = LedgerSMB::Template->new( 
            locale => $request->{_locale},
            user => $user, 
    	    template => 'form-dynatable', 
    	    language => $user->{language}, 
            format => 'HTML',
            path=>"UI");
        
        my $column_heading = $template->column_heading($column_names,
            {href => $sort_href, columns => \@sort_columns}
        );
        
        return $template->render({
		form     => $recon,
		heading  => $column_heading,
        	hiddens  => $recon,
		columns  => $cols,
		rows     => \@results
	});
        
}

=item 

Displays search criteria screen

=cut

sub search {
    my ($request,$type) = @_;
    
    my $recon = LedgerSMB::DBObject::Reconciliation->new(base=>$request, copy=>'all');
	if (!$recon->{hide_status}){
            $recon->{show_approved} = 1;        
            $recon->{show_submitted} = 1;        
        }
        @{$recon->{account_list}} = $recon->get_accounts();
	unshift @{$recon->{account_list}}, {id => '', name => '' };
        my $template = LedgerSMB::Template->new(
            user => $user,
            template=>'search',
            language=>$user->{language},
            format=>'HTML',
            path=>"UI/reconciliation",
        );
        return $template->render($recon);
}

=pod

=over

=item new_report ($self, $request, $user)

Creates a new report, from a selectable set of bank statements that have been
received (or can be received from, depending on implementation)

Allows for an optional selection key, which will return the new report after
it has been created.

=back

=cut

sub _display_report {
        my $recon = shift;
        $recon->get();
        $recon->close_form;
        $recon->open_form({commit => 1});
        $recon->add_entries($recon->import_file('csv_file')) if !$recon->{submitted};
        $recon->{can_approve} = $recon->is_allowed_role({allowed_roles => ['reconciliation_approve']});
        $recon->get();
        $template = LedgerSMB::Template->new( 
            user=> $user,
            template => 'reconciliation/report', 
            language => $user->{language},
            format=>'HTML',
            path=>"UI"
        );
        $recon->{sort_options} = [
		{id => 'clear_time', label => $recon->{_locale}->text('Clear date')},
		{id => 'scn', label => $recon->{_locale}->text('Source')},
		{id => 'post_date', label => $recon->{_locale}->text('Post Date')},
		{id => 'our_balance', label => $recon->{_locale}->text('Our Balance')},
		{id => 'their_balance', label => $recon->{_locale}->text('Their Balance')},
        ];
        if (!$recon->{line_order}){
           $recon->{line_order} = 'scn';
        }
        $recon->{total_cleared_credits} = $recon->parse_amount(amount => 0);
        $recon->{total_cleared_debits} = $recon->parse_amount(amount => 0);
        $recon->{total_uncleared_credits} = $recon->parse_amount(amount => 0);
        $recon->{total_uncleared_debits} = $recon->parse_amount(amount => 0);
        my $neg_factor = 1;
        if ($recon->{account_info}->{category} =~ /(A|E)/){
           $recon->{their_total} *= -1;
           $neg_factor = -1;
           
        }


        # Credit/Debit separation (useful for some)
        for my $l (@{$recon->{report_lines}}){
            if ($l->{their_balance} > 0){
               $l->{their_debits} = $recon->parse_amount(amount => 0);
               $l->{their_credits} = $l->{their_balance};
            }
            else {
               $l->{their_credits} = $recon->parse_amount(amount => 0);
               $l->{their_debits} = $l->{their_balance}->bneg;
            }
            if ($l->{our_balance} > 0){
               $l->{our_debits} = $recon->parse_amount(amount => 0);
               $l->{our_credits} = $l->{our_balance};
            }
            else {
               $l->{our_credits} = $recon->parse_amount(amount => 0);
               $l->{our_debits} = $l->{our_balance}->bneg;
            }

            if ($l->{cleared}){
                 $recon->{total_cleared_credits}->badd($l->{our_credits});
                 $recon->{total_cleared_debits}->badd($l->{our_debits});
            } else {
                 $recon->{total_uncleared_credits}->badd($l->{our_credits});
                 $recon->{total_uncleared_debits}->badd($l->{our_debits});
            }

            $l->{their_balance} = $recon->format_amount({amount => $l->{their_balance}, money => 1});
            $l->{our_balance} = $recon->format_amount({amount => $l->{our_balance}, money => 1});
            $l->{their_debits} = $recon->format_amount({amount => $l->{their_debits}, money => 1});
            $l->{their_credits} = $recon->format_amount({amount => $l->{their_credits}, money => 1});
            $l->{our_debits} = $recon->format_amount({amount => $l->{our_debits}, money => 1});
            $l->{our_credits} = $recon->format_amount({amount => $l->{our_credits}, money => 1});
        }

	$recon->{zero_string} = $recon->format_amount({amount => 0, money => 1});

	$recon->{statement_gl_calc} = $neg_factor * 
                ($recon->{their_total}
		+ $recon->{outstanding_total} 
                + $recon->{mismatch_our_total});
        print STDERR "debug: $recon->{their_total} - $recon->{our_total}\n";
	$recon->{out_of_balance} = $recon->{their_total} - $recon->{our_total};
        $recon->{cleared_total} = $recon->format_amount({amount => $recon->{cleared_total}, money => 1});
        $recon->{outstanding_total} = $recon->format_amount({amount => $recon->{outstanding_total}, money => 1});
        $recon->{mismatch_our_debits} = $recon->format_amount(
		{amount => $recon->{mismatch_our_debits}, money => 1});
        $recon->{mismatch_our_credits} = $recon->format_amount(
		{amount => $recon->{mismatch_our_credits}, money => 1});
        $recon->{mismatch_their_debits} = $recon->format_amount(
		{amount => $recon->{mismatch_their_debits}, money => 1});
        $recon->{mismatch_their_credits} = $recon->format_amount(
		{amount => $recon->{mismatch_their_credits}, money => 1});
        $recon->{statement_gl_calc} = $recon->format_amount(
		{amount => $recon->{statement_gl_calc}, money => 1});
        $recon->{total_cleared_debits} = $recon->format_amount(
              {amount => $recon->{total_cleared_debits}, money => 1}
        );
        $recon->{total_cleared_credits} = $recon->format_amount(
               {amount => $recon->{total_cleared_credits}, money => 1}
        );
        $recon->{total_uncleared_debits} = $recon->format_amount(
              {amount => $recon->{total_uncleared_debits}, money => 1}
        );
        $recon->{total_uncleared_credits} = $recon->format_amount(
               {amount => $recon->{total_uncleared_credits}, money => 1}
        );
	$recon->{their_total} = $recon->format_amount(
		{amount => $recon->{their_total}, money => 1});
	$recon->{our_total} = $recon->format_amount(
		{amount => $recon->{our_total}, money => 1});
	$recon->{beginning_balance} = $recon->format_amount(
		{amount => $recon->{beginning_balance}, money => 1});
	$recon->{out_of_balance} = $recon->format_amount(
		{amount => $recon->{out_of_balance}, money => 1});
        if ($recon->{account_info}->{category} =~ /(A|E)/){
           $recon->{their_total} *= -1;
        }

        return $template->render($recon);
}


=item new_report

Displays the new report screen.

=cut
sub new_report {
    my ($request) = @_;
    
    my $template;
    my $return;
    my $recon = LedgerSMB::DBObject::Reconciliation->new(base => $request, copy => 'all'); 
    if ($request->type() eq "POST") {
        
        # We can assume that we're doing something useful with new data.
        # We can also assume that we've got a file.
        
        # $self is expected to have both the file handling logic, as well as 
        # the logic to load the processing module.
        
        # Why isn't this testing for errors?
        my ($report_id, $entries) = $recon->new_report($recon->import_file());
        $recon->{dbh}->commit;
        if ($recon->{error}) {
            #$recon->{error};
            
            $template = LedgerSMB::Template->new(
                user=>$user,
                template=> 'reconciliation/upload',
                language=>$user->{language},
                format=>'HTML',
                path=>"UI"
            );
            return $template->render($recon);
        }
        _display_report($recon);
    }
    else {
        
        # we can assume we're to generate the "Make a happy new report!" page.
        @{$recon->{accounts}} = $recon->get_accounts;
        $template = LedgerSMB::Template->new( 
            user => $user, 
            template => 'reconciliation/upload', 
            language => $user->{language}, 
            format => 'HTML',
            path=>"UI"
        );
        return $template->render($recon);
    }
    return undef;
    
}

=pod

=over

=item delete_report ($request)

Requires report_id

Deletes the given report_id, and marks whom it was deleted by.
Will fail if the report does not exist, or if the report has already been
approved.

TO BE DETERMINED:
Whether or not a delete is permissable by the same user that created the 
report.
=back

=cut

sub delete_report {
    
    
    my ($request) = @_;
    
    my $recon = LedgerSMB::DBObject::Reconciliation->new(base=>$request, copy=>'all');
    
    # report_id should be set in the request object. It should be an int, and 
    # it should correspond to one of the reports.
    
    if ($request->type() eq "POST") {
        
        $resp = $recon->delete_report($request->{report_id});
        
        if ($resp) {
            
            # This is good; we have a true-like response.
            # Drop the report_id and send the request to search()
            delete($request->{report_id});
            return search($request);
        }
        return undef;
    }
    else {
        # this is wrong - We should never get a GET request here. This should 
        # throw an error? Or redirect back to the display page?
        return undef;
    }
}

=pod

=over

=item approve ($self, $request, $user)

Requires report_id

Approves the given report based on id. Generally, the roles should be 
configured so as to disallow the same user from approving, as created the report.

Returns a success page on success, returns a new report on failure, showing 
the uncorrected entries.

=back

=cut

sub approve {
    my ($request) = @_;
    if (!$request->close_form){
        get_results($request);
        $request->finalize_request();
    }
    
    # Approve will also display the report in a blurred/opaqued out version,
    # with the controls removed/disabled, so that we know that it has in fact
    # been cleared. This will also provide for return-home links, auditing, 
    # etc.
    
    if ($request->type() eq "POST") {
        
        # we need a report_id for this.
        
        my $recon = LedgerSMB::DBObject::Reconciliation->new(base => $request, copy=> 'all');

        my $template;
        my $code = $recon->approve($request->{report_id});
        if ($code == 0) {

            $template = LedgerSMB::Template->new( user => $user, 
        	template => 'reconciliation/approved', language => $user->{language}, 
                format => 'HTML',
                path=>"UI"
                );
                
            return $template->render($recon);
        }
        else {
            
            # failure case
            
            $template = LedgerSMB::Template->new( 
                user => $user, 
        	    template => 'reconciliation/report', 
        	    language => $user->{language}, 
                format => 'HTML',
                path=>"UI"
                );
            return $template->render($recon
            );
        }
    }
    else {
        return $class->display_report($request);
    }
}

=pod

=over

=item pending ($self, $request, $user)

Requires {date} and {month}, to handle the month-to-month pending transactions
in the database. No mechanism is provided to grab ALL pending transactions 
from the acc_trans table.

=back

=cut


sub pending {
    
    my ($request) = @_;
    
    my $recon = LedgerSMB::DBObject::Reconciliation->new(base=>$request, copy=>'all');
    my $template;
    
    $template= LedgerSMB::Template->new(
        user => $user,
        template=>'reconciliation/pending',
        language=>$user->{language},
        format=>'HTML',
        path=>"UI"
    );
    if ($request->type() eq "POST") {
        return $template->render(
            {
                pending=>$recon->get_pending($request->{year}."-".$request->{month})
            }
        );
    } 
    else {
        
        return $template->render();
    }
}

sub __default {
    
    my ($request) = @_;
    
    $request->error(Dumper($request));
    
    my $recon = LedgerSMB::DBObject::Reconciliation->new(base=>$request, copy=>'all');
    my $template;
    
    $template = LedgerSMB::Template->new(
        user => $user,
        template => 'reconciliation/list',
        language => $user->{language},
        format=>'HTML',
        path=>"UI"
    );
    return $template->render(
        {
            reports=>$recon->get_report_list()
        }
    );
}

 eval { do "scripts/custom/recon.pl" };
1;

=pod

=head1 Copyright (C) 2007, The LedgerSMB core team.

This file is licensed under the Gnu General Public License version 2, or at your
option any later version.  A copy of the license should have been included with
your software.

=cut
