# RPM spec written for and tested on CentOS 4 and CentOS 5 
Summary: LedgerSMB - Open Source accounting software
Name: ledgersmb
Version: 1.3.0_rc2
Release: 1
License: GPL
URL: http://www.ledgersmb.org/
Group: Applications/Productivity
Source0: %{name}-%{version}.tar.gz
Source1: Config-Std-0.007.tar.gz
Source2: Template-Plugin-Latex-3.02.tar.gz
BuildRoot: %{_tmppath}/%{name}-%{version}-root
BuildArch: noarch
Requires: perl >= 5.8, httpd, postgresql >= 8.1, tetex-latex
Requires: perl-DBD-Pg >= 2.0 , perl-DBI >= 1.48
Requires: perl-version, perl-Smart-Comments
Requires: perl-HTML-Parser, perl-Template-Toolkit, 
Requires: perl-Error, perl-CGI-Simple
Requires: perl-File-MimeInfo, perl-IO-stringy
Requires: perl-MIME-Lite, perl-Class-Std >= 0.0.8
Requires: perl-Locale-Maketext-Lexicon >= 0.62
Requires: perl-IO-String
Requires: perl-Math-BigInt-GMP
BuildRequires: perl
# avoid bogus autodetection of perl modules:
AutoReqProv: no


%description
LedgerSMB is a double-entry accounting system written in perl.
LedgerSMB is a fork of sql-ledger offering better security and data integrity,
and many advanced features.

This package does not work in SELinux restricted mode.  However audit2allow can
be used to ensure that it will work.  Start with permissive mode, and then once
issues are corrected, you can turn the mode back to restricted.

To finalize the ledgersmb installation:

Enable local password autentication in PosgreSQL, leaving ident login for the
postgres user:
- Start PostgreSQL to create database instance (service postgres start)
- Let /var/lib/pgsql/data/pg_hba.conf start with:
local   all         postgres                          ident sameuser
local   all         all                               md5
host    all         all         127.0.0.1/32          md5
- Restart PostgreSQL to apply changes (service postgres restart)

In %{_sysconfdir}/%{name}/ledgersmb.conf set DBPassword to something
and create the ledgersmb master user and database:
su - postgres -c "createuser -d ledgersmb --createdb --superuser -P"
su - postgres -c "createdb ledgersmb"
su - postgres -c "createlang plpgsql ledgersmb"
su - postgres -c "psql ledgersmb < %{_datadir}/%{name}/sql/Pg-central.sql"
Bleeding edge hint: Set password to avoid bogus web prompt:
su - postgres -c "psql ledgersmb -c \"update users_conf set password = md5('yada') where id = 1;\""

Visit http://localhost/ledgersmb/admin.pl with password "yada" and create an
application database and users.


%prep
%setup -q -n ledgersmb

chmod 0644 $(find . -type f)
chmod 0755 $(find . -type d)
chmod +x *.pl
chmod -x pos.conf.pl custom.pl # FIXME: Config???
chmod +x utils/*/*.pl utils/devel/find-use utils/pos/pos-hardware-client-startup-script


%build

cat << TAK > rpm-ledgersmb-httpd.conf
Alias /ledgersmb/doc/LedgerSMB-manual.pdf %{_docdir}/%{name}-%{version}/LedgerSMB-manual.pdf
<Files %{_docdir}/%{name}-%{version}/LedgerSMB-manual.pdf>
</Files>

TAK

perl -p -e "s,/some/path/to/ledgersmb,%{_datadir}/%{name},g" ledgersmb-httpd.conf >> rpm-ledgersmb-httpd.conf


%install

rm -rf $RPM_BUILD_ROOT
mkdir -p -m0755 $RPM_BUILD_ROOT%{_datadir}/%{name} # /usr/lib/ledgersmb - readonly code and cgi directory
mkdir -p -m0750 $RPM_BUILD_ROOT%{_sysconfdir}/%{name} # /etc/ledgersmb - configs
mkdir -p -m0750 $RPM_BUILD_ROOT%{_localstatedir}/lib/%{name} # /var/lib/ledgersmb - data files, modified by cgi
mkdir -p -m0750 $RPM_BUILD_ROOT%{_localstatedir}/spool/%{name} # /var/spool/ledgersmb - spool files, modified by cgi

# the conf, placed in etc, symlinked back in place
mv ledgersmb.conf.default $RPM_BUILD_ROOT%{_sysconfdir}/ledgersmb/ledgersmb.conf
ln -s ../../..%{_sysconfdir}/ledgersmb/ledgersmb.conf \
  $RPM_BUILD_ROOT%{_datadir}/%{name}/ledgersmb.conf

# install relevant parts in data/cgi directory
rm -rf $RPM_BUILD_ROOT%{_datadir}/%{name}/locale/legacy

# css - written to by cgi
mkdir -p -m0750 $RPM_BUILD_ROOT%{_localstatedir}/lib/%{name}/css
ln -s ../../..%{_localstatedir}/lib/%{name}/css \
  $RPM_BUILD_ROOT%{_datadir}/%{name}/css
cp -rp css/* \
  $RPM_BUILD_ROOT%{_datadir}/%{name}/css

# templates - written to by cgi
mkdir -p -m0750 $RPM_BUILD_ROOT%{_localstatedir}/lib/%{name}/templates
ln -s ../../..%{_localstatedir}/lib/%{name}/templates \
  $RPM_BUILD_ROOT%{_datadir}/%{name}/templates
cp -rp templates/* \
  $RPM_BUILD_ROOT%{_datadir}/%{name}/templates

# spool - written to by cgi
mkdir -p $RPM_BUILD_ROOT%{_localstatedir}/spool/%{name}
ln -s ../../..%{_localstatedir}/spool/%{name} \
  $RPM_BUILD_ROOT%{_datadir}/%{name}/spool

# apache config file
mkdir -p $RPM_BUILD_ROOT%{_sysconfdir}/httpd/conf.d
install -m 644 rpm-ledgersmb-httpd.conf \
  $RPM_BUILD_ROOT%{_sysconfdir}/httpd/conf.d/ledgersmb.conf

%clean
rm -rf $RPM_BUILD_ROOT


%files
%defattr(-,root,root)

%{_datadir}/%{name}

%attr(-, apache, apache) %config(noreplace) %{_localstatedir}/lib/%{name}
%attr(-, apache, apache) %dir %{_localstatedir}/spool/%{name}

%attr(0750, root, apache) %dir %{_sysconfdir}/%{name}
%attr(0640, root, apache) %config(noreplace) %{_sysconfdir}/%{name}/*

%config(noreplace) %{_sysconfdir}/httpd/conf.d/*.conf

%doc doc/{COPYRIGHT,faq.html,LedgerSMB-manual.pdf,README,release_notes}
%doc BUGS Changelog CONTRIBUTORS INSTALL LICENSE README.translations UPGRADE


%changelog
* Mon Dec 31 2007 Christopher Murtagh <cmurtagh@ledgersmb.org> - 1.2.11
- updating to 1.2.11
- removing users directory

* Wed Jun 13 2007 David Fetter <david@fetter.org> 1.25-2
- Updated to 1.25
- Use perl-* RPM packages rather than bundling them

* Fri Nov 10 2006 Mads Kiilerich <mads@kiilerich.com> - 1.2-alpha
- Updating towards 1.2

* Wed Oct 18 2006 Mads Kiilerich <mads@kiilerich.com> - 1.1.1d-1
- Initial version
