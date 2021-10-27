# Koha plugin for IdRef

This plugins allows to import authorities from https://www.idref.fr/

## Requirements

This plugin requires patch from
[Bug 29333](https://bugs.koha-community.org/bugzilla3/show_bug.cgi?id=29333)
to work correctly.

Without it you will encounter encoding issues.

## Usage

When installed and enabled, the plugin adds a button "New from IdRef" in
authorities toolbar. Click on this button to access a search form in a popup
window.

Submit the form to get results directly from IdRef. From there you will be able
to:

* preview MARC records
* import a record in a new Koha authority
