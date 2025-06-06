import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart';
import 'package:uuid/uuid.dart';
import 'package:yaml/yaml.dart';

import 'console_color.dart';
import 'templates.dart';

const kVersion = 'DEV';
const kRepository = 'https://github.com/ygimenez/build_script';
const kBlobs = 'https://raw.githubusercontent.com/ygimenez/build_script/refs/heads/master';
const kIsRelease = kVersion != 'DEV';
const kChocoInstall =
    "Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))";

final cli = http.Client();
final exe = File(kIsRelease ? 'build_script.exe' : basename(Platform.script.path));
final outdated = <String>[];

void main(List<String> args) async {
  try {
    final isAdmin = bool.parse(
      await Process.run('powershell', [
        '([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)',
      ]).then((p) => (p.stdout as String).toLowerCase().trim()),
    );

    if (kIsRelease && !isAdmin) {
      error('This program requires elevation');
      throw "Not admin";
    }

    if (args.length < 2) args = ['', ''];
    var [appName, appVersion] = args;

    if (kIsRelease) {
      final pubspec = File('pubspec.yaml');
      if (await pubspec.exists()) {
        final yaml = loadYaml(await pubspec.readAsString());
        if (yaml['dependencies']?['flutter']?['sdk'] != 'flutter') {
          error('Project is not a flutter project');
          throw "Not a flutter project";
        }

        appName = yaml['app_name'] ?? appName;
        appVersion = yaml['version'] ?? appVersion;
      } else {
        error('Pubspec not found, this program must be placed at project root');
        throw "Wrong root";
      }
    }

    info('App name: ');
    if (appName.isEmpty) {
      appName = (stdin.readLineSync() ?? '').replaceAll(' ', '').trim();
    } else {
      info(appName, true);
    }

    info('App version: ');
    if (appVersion.isEmpty) {
      appVersion = (stdin.readLineSync() ?? '').replaceAll(' ', '').trim();
    } else {
      info(appVersion, true);
    }

    if (appName.isEmpty || appVersion.isEmpty) {
      error('An app name and version are required');
      info(
        '''
        Usage:
        - ${Platform.script.pathSegments.last} ${Green('[App name]')} ${Green('[App version]')}
        '''
            .replaceAll(RegExp(r'^\s+', multiLine: true), ''),
      );

      throw "No app name or version";
    }

    if (kIsRelease) {
      final pubspec = File('pubspec.yaml');
      final lines = await pubspec.readAsLines();
      final idx = lines.indexWhere((l) => l.startsWith('description:'));

      if (!lines.any((l) => l.startsWith('app_name:'))) {
        lines.insert(idx + 1, 'app_name: $appName');
        info('App name parameter added to pubspec, future executions will read from there instead');
      }

      if (!lines.any((l) => l.startsWith('version:'))) {
        lines.insert(idx + 1, 'version: $appVersion');
        info('App version parameter added to pubspec, future executions will read from there instead');
      }

      await pubspec.writeAsString(lines.join('\n'));
    }

    info('BuildScript Version $kVersion');

    info('---------------------------------------------------');

    info('Checking for updates...');
    final res = await cli.send(http.Request('HEAD', Uri.parse('$kRepository/releases/latest'))..followRedirects = false);
    if (res.headers.containsKey('location')) {
      final latest = res.headers['location']!.split('/').last;

      if (kVersion != latest) {
        info('available', true);
        if (kIsRelease) {
          await exe.rename('${exe.path}.old');
        }

        info('Downloading new version');
        final resExe = await http.get(Uri.parse('$kRepository/releases/download/$latest/build_script.exe'));
        info(Green('Download complete'));

        final hash = md5.convert(resExe.bodyBytes).toString().toUpperCase();
        {
          final resHash = await http.get(Uri.parse('$kRepository/releases/download/$latest/checksum.md5'));
          if (hash == resHash.body.trim()) {
            if (kIsRelease) {
              info('Restarting program...');
              await exe.writeAsBytes(resExe.bodyBytes, flush: true);
              await Process.start('powershell', ['del "${exe.path}.old"; start "${exe.path}" ${args.join(' ')}'], runInShell: true);
              exit(0);
            }
          } else {
            warn('Checksum mismatch, aborting update');
          }
        }
      } else {
        info('up-to-date', true);
      }
    } else {
      warn('Unable to retrieve latest version');
    }

    info('---------------------------------------------------');

    info('Checking dependencies');
    final deps = {
      'Chocolatey': () async => await exec('choco', args: ['--version'], packageId: 'chocolatey', installScript: kChocoInstall, writeOutput: false),
      'Dart SDK': () async => await exec('dart', args: ['--version'], packageId: 'dart-sdk', writeOutput: false),
      'Flutter SDK': () async => await exec('flutter', args: ['--version'], packageId: 'flutter', writeOutput: false),
      'Inno Setup': () async => await exec('iscc', args: ['/?'], path: r'C:\Program Files (x86)\Inno Setup 6\', packageId: 'innosetup', writeOutput: false),
      'WinRAR': () async => await exec('rar', args: ['-iver'], path: r'C:\Program Files\WinRAR\', packageId: 'winrar', writeOutput: false),
    };

    for (final e in deps.entries) {
      info('${e.key}: ');
      await e.value();
      info(Cyan('OK'), true);
    }

    info('---------------------------------------------------');

    final gitignore = File('.gitignore');
    if (await gitignore.exists()) {
      final lines = await gitignore.readAsLines();
      if (!lines.any((l) => l == '# Added by build_script')) {
        lines.addAll([
          '',
          '# Added by build_script',
          'output/',
          '/*.iss',
        ]);

        await gitignore.writeAsString(lines.join('\n'));
        info('Added paths to .gitignore');
      }
    }

    await exec('flutter', args: ['clean']);

    final output = Directory('./output');
    if (!await output.exists()) {
      await output.create();
    } else {
      await for (final f in output.list()) {
        await f.delete();
      }
    }

    if (await Directory('./windows').exists()) {
      info('--------------------- WINDOWS ---------------------');

      /* Remake Installer */
      {
        final pubspec = File('pubspec.yaml');
        final yaml = loadYaml(await pubspec.readAsString());

        final installer = File('Installer.iss');
        final nameParts = appName.split(RegExp(r'(?<=.)(?=[A-Z][a-z])'));
        final uuid = Uuid();

        final props = {
          'TITLE': nameParts.join(' '),
          'VERSION': appVersion,
          'EXENAME': yaml['name'],
          'GUID': uuid.v5(Namespace.url.value, 'bels.com.br/${yaml['name']}'),
          'NAME': appName,
        };

        await installer.writeAsString(kInstaller.replaceAllMapped(RegExp(r'{{(\w+)}}'), (match) => props[match[1]] ?? ""));
      }

      /* Remake CodeDependencies */
      {
        final res = await http.get(Uri.parse('https://raw.githubusercontent.com/DomGries/InnoDependencyInstaller/refs/heads/master/CodeDependencies.iss'));
        if (res.statusCode ~/ 100 == 2) {
          final codeDeps = File('CodeDependencies.iss');
          await codeDeps.writeAsBytes(res.bodyBytes);
        }
      }

      final icon = File('asset/installer.ico');
      if (!await icon.exists()) {
        warn('Installer icon not found, using fallback icon (path: ./asset/installer.ico)');
        final res = await http.get(Uri.parse('$kBlobs/fallback/installer.ico'));
        await icon.writeAsBytes(res.bodyBytes);
      }

      await exec('flutter', args: ['build', 'windows']) &&
          await exec('iscc', args: ['Installer.iss'], path: r'C:\Program Files (x86)\Inno Setup 6\') &&
          await exec('rar',
              args: ['a', '-df', '-ep1', join(output.path, 'Windows_${appName}_$appVersion.rar'), join(output.path, '${appName}_setup.exe')], path: r'C:\Program Files\WinRAR\');
    }

    if (await Directory('./android').exists()) {
      info('--------------------- ANDROID ---------------------');

      final built = await exec('flutter', args: ['build', 'apk']);
      if (built) {
        File apk = File('build/app/outputs/flutter-apk/app-release.apk');
        if (await apk.exists()) {
          apk = await apk.rename('${apk.parent.path}/$appName.apk');
          await exec('rar', args: ['a', '-ep1', join(output.path, 'Android_${appName}_$appVersion.rar'), apk.path], path: r'C:\Program Files\WinRAR\');
        }
      }
    }

    if (await Directory('./linux').exists()) {
      info('---------------------  LINUX  ---------------------');
      // NOT IMPLEMENTED
    }

    if (await Directory('./web').exists()) {
      info('---------------------   WEB   ---------------------');

      final built = await exec('flutter', args: ['build', 'web']);
      if (built) {
        final dir = Directory('build/web');
        await exec('rar', args: ['a', '-r', '-ep1', join(output.path, 'Web_${appName}_$appVersion.rar'), join(dir.path, '*')], path: r'C:\Program Files\WinRAR\');
      }
    }
  } catch (e) {
    error(e);
    info('\nPress any key to exit...');
    stdin.readLineSync();
    exit(1);
  } finally {
    info('\nPress any key to exit...');
    stdin.readLineSync();
    exit(0);
  }
}

Future<bool> exec(String program, {String path = '', List<String> args = const [], String? packageId, String? installScript, bool writeOutput = true}) async {
  try {
    if (packageId != null) {
      if (packageId == 'chocolatey') {
        final String out = await Process.run('choco', ['outdated']).then((p) => p.stdout);
        final rex = RegExp(r'([\w-.]+?)\|[\d.]+?\|[\d.]+?\|false', multiLine: true);
        for (final m in rex.allMatches(out)) {
          outdated.add(m.group(1)!);
        }
      }

      if (outdated.contains(packageId)) {
        info('New version found, type "y" to update: ');
        final opt = (stdin.readLineSync() ?? '').toLowerCase();
        if (opt == 'y') {
          await Process.run('choco', ['upgrade', '-y', packageId]);
        }
      }
    }

    if (writeOutput) {
      info('');
      return await Process.start('$path$program', args, runInShell: true, mode: ProcessStartMode.inheritStdio).then((p) => p.exitCode) == 0;
    }

    return await Process.run('$path$program', args, runInShell: true).then((p) => p.exitCode) == 0;
  } on ProcessException {
    if (packageId != null || installScript != null) {
      info("Process '$program' not found, installing...\n");

      if (installScript != null) {
        final prog = installScript.split(' ').first;
        final args = installScript.replaceFirst(prog, '').trim();

        if (await Process.start(prog, [args], mode: ProcessStartMode.inheritStdio).then((p) => p.exitCode) != 0) {
          error("Failed to install dependency '$program', aborting execution");
          throw "Failed to install dependency";
        }
      }

      info("Installed '$program' successfully");
      return exec(program, path: path, args: args, packageId: packageId, installScript: installScript, writeOutput: writeOutput);
    }

    error("Process '$program' not found, please install before proceeding");
    throw "Dependency unmet";
  }
}

void info(content, [bool inline = false]) {
  log(Default(content), inline);
}

void warn(content, [bool inline = false]) {
  log(Yellow(content), inline);
}

void error(content, [bool inline = false]) {
  log(Red(content), inline);
}

void log(ConsoleColor content, [bool inline = false]) {
  stdout.write('${inline ? '' : '\n'}$content');
}
