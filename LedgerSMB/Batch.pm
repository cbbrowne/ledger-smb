=head1 NAME
LedgerSMB::Batch

=head1 SYNOPSIS
Batch/voucher management model for LedgerSMB 1.3

=head1 METHODS

=over

=cut

package LedgerSMB::Batch;
use LedgerSMB::Setting;
use base qw(LedgerSMB::DBObject);

=item get_new_info

This gets the information required for the new batch screen.  Currently this
just populates the batch_number hashref value.

=cut

sub get_new_info {
    $self = shift @_;
    my $cc_object = LedgerSMB::Setting->new({base => $self});
    $cc_object->{key} = 'batch_cc';
    $self->{batch_number} = $cc_object->increment;
    $self->{dbh}->commit;
}

=item create

Saves the batch info and populates the id hashref value with the id inserted.

=cut

sub create {
    $self = shift @_;
    my ($ref) = $self->exec_method(funcname => 'batch_create');
    $self->{id} = $ref->{batch_create};
    $self->{dbh}->commit;
    return $ref->{id};
}

=item delete_voucher($id)

Deletes the voucher specified by $id. 

=cut

sub delete_voucher {
    my ($self, $voucher_id) = @_;
    $self->call_procedure(procname => 'voucher__delete', args => [$voucher_id]);
    $self->{dbh}->commit;
}

=item get_search_criteria
Sets all hash values needed for the search interface:

=over

=item batch_classes
List of all batch classes

=item batch_users
List of all users

=back

=cut

sub get_search_criteria {
    $self = shift @_;
    my ($custom_types) = @_;
    @{$self->{batch_classes}} = $self->exec_method(
         funcname => 'batch_list_classes'
    );
    for (keys %$custom_types){
        if ($custom_types->{$_}->{map_to}){
            push @{$self->{batch_classes}}, {id => $_, class => $_};
        }
    }

    @{$self->{batch_users}} = $self->exec_method(
         funcname => 'batch_get_users'
    );
    unshift @{$self->{batch_users}}, {username => $self->{_locale}->text('Any'), id => '0', entity_id => '0'};
}

=item get_search_method (private)

Determines the appropriate search method, either for empty, mini, or full 
searches

Returns the appropriate stored proc name.

=cut

# This needs to be refactored.  Input sanitation should be moved to 
# get_search_results
sub get_search_method {
	my ($self, @args) = @_;
	my $search_proc;
	
	if ($self->{empty}){
        $search_proc = "batch_search_empty";
    } elsif ($args->{mini}){
        $search_proc = "batch_search_mini";
    } else {
        $search_proc = "batch_search";
    }

    if ( !defined $self->{created_by_eid} || $self->{created_by_eid} == 0){
		delete $self->{created_by_eid};
    }

    if ( !defined $self->{class_id} )
    {
        delete $self->{class_id};
    }

    if ( ( defined $args->{custom_types} ) && ( defined $self->{class_id} ) && ( $args->{custom_types}->{$self->{class_id}}->{select_method} ) ){
        $search_proc 
             = $args->{custom_types}->{$self->{class_id}}->{select_method}; 
    } elsif ( ( defined $self->{class_id} ) && ( $self->{class_id} =~ /[\D]/ ) ){
          $self->error("Invalid Batch Type");
    }

	return $search_proc;
}

=item get_search_results

Returns the appropriate search as detected by get_search_method.

=cut

sub get_search_results {
    my ($self, $args) = @_;
	my $search_proc = $self->get_search_method($args);
    @{$self->{search_results}} = $self->exec_method(funcname => $search_proc);
    return @{$self->{search_results}};
}

=item get_class_id($type)

Returns the class_id of batch class specified by its label.

=cut

sub get_class_id {
    my ($self, $type) = @_;
    @results = $self->call_procedure(
                                     procname => 'batch_get_class_id', 
                                     args     => [$type]
    );
    my $result = pop @results;
    return $result->{batch_get_class_id};
}

=item post

Posts a batch to the books and makes the vouchers show up in transaction 
reports, financial statements, and more.

=cut

sub post {
    my ($self) = @_;
    ($self->{post_return_ref}) = $self->exec_method(funcname => 'batch_post');
    $self->{dbh}->commit;
    return $self->{post_return_ref};
}

=item delete

Deletes the unapproved batch and all vouchers under it.

=cut

sub delete {
    my ($self) = @_;
    ($self->{delete_ref}) = $self->exec_method(funcname => 'batch_delete');
    $self->{dbh}->commit;
    return $self->{delete_ref};
}

=item list_vouchers
Returns a list of all vouchers in the batch and attaches that list to 
$self->{vouchers}

=cut

sub list_vouchers {
    my ($self) = @_;
    @{$self->{vouchers}} = $self->exec_method(funcname => 'voucher_list');
    return @{$self->{vouchers}};
}

=item get

Gets the batch and merges information with the current batch object.

=cut

sub get {
    my ($self) = @_;
    my ($ref) = $self->exec_method(funcname => 'voucher_get_batch');
    $self->merge($ref);
}

1;

=back

=head1 Copyright (C) 2009, The LedgerSMB core team.

This file is licensed under the Gnu General Public License version 2, or at your
option any later version.  A copy of the license should have been included with
your software.

=cut
