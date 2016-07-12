/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/*
 * Copyright 2016 Joyent, Inc.
 */

/*
 * This program allows "lib/util.sh" to create an initial "config-agent"
 * configuration file, and to incrementally add local manifest directories
 * to an existing file.  It is intentionally written to work on old (and
 * new!) Node versions and to avoid any non-core dependencies.
 */

var mod_fs = require('fs');

function
fatal(msg)
{
	console.error('ERROR: %s %s: %s', process.argv[0], process.argv[1],
	    msg);
	process.exit(1);
}

function
store_file(path, obj)
{
	var str = JSON.stringify(obj, null, 4) + '\n';

	try {
		mod_fs.writeFileSync(path, str);
	} catch (ex) {
		fatal('failed to write file "' + path + '": ' + ex.message);
	}
}

function
load_file(path)
{
	var buf;
	var obj;

	try {
		buf = mod_fs.readFileSync(path).toString('utf8');
	} catch (ex) {
		fatal('failed to read file "' + path + '": ' + ex.message);
	}

	try {
		obj = JSON.parse(buf);
	} catch (ex) {
		fatal('failed to parse file "' + path + '": ' + ex.message);
	}

	return (obj);
}

function
parse_manifest_dirs(input)
{
	var dirs = [];

	if (!input) {
		return (dirs);
	}

	var t = input.split(/[ \t]+/);

	for (var i = 0; i < t.length; i++) {
		var dir = t[i].trim();

		if (dir && dirs.indexOf(dir) === -1) {
			dirs.push(dir);
		}
	}

	return (dirs);
}

(function
main()
{
	var cmd = process.argv[2];
	var config;
	var config_file = process.argv[3];

	if (!cmd || !config_file) {
		fatal('require at least a command and a config file ' +
		    'argument');
	}

	switch (cmd) {
	case 'init':
		/*
		 * Create the initial "config-agent" configuration file.
		 *
		 * Extra arguments:
		 *   - a SAPI URL
		 *   - a list of zero or more local manifest directories
		 *     as a space-separated string
		 */
		var url = process.argv[4];
		var dirlist = process.argv[5];

		if (!url) {
			fatal('require a SAPI URL');
		}

		config = {
			logLevel: 'info',
			pollInterval: 60 * 1000,
			sapi: {
				url: url
			},
			localManifestDirs: parse_manifest_dirs(dirlist)
		};

		store_file(config_file, config);
		break;

	case 'add_manifest_dir':
		/*
		 * Load an existing "config-agent" configuration file
		 * and add a single local manifest directory to the list.
		 *
		 * Extra aguments:
		 *   - a single local manifest directory path
		 */
		var dir = process.argv[4];
		if (!dir) {
			fatal('require a local manifest directory');
		}

		config = load_file(config_file);

		if (!config.localManifestDirs) {
			config.localManifestDirs = [];
		}
		if (config.localManifestDirs.indexOf(dir) === -1) {
			config.localManifestDirs.push(dir);
		}

		store_file(config_file, config);
		break;

	default:
		fatal('invalid command: ' + cmd);
		break;
	}
})();

/* vim: set ts=8 sts=8 sw=8 noet: */
