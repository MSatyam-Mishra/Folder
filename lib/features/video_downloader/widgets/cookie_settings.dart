import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:folders/core/platform/desktop.dart';
import 'package:folders/core/services/video_downloader/cookie_store.dart';
import 'package:folders/core/services/video_downloader/netscape_cookies.dart';
import 'package:folders/core/services/video_downloader/video_downloader_controller.dart';
import 'package:folders/features/viewer_kit/viewer_kit.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../screens/site_login_screen.dart';

/// The Cookies part of the downloader settings: an imported cookies.txt
/// file, a row per site (sign in, paste cookies, sign out), adding sites,
/// and a short help.
class CookieSettingsCard extends StatelessWidget {
  const CookieSettingsCard({super.key, required this.controller});

  final VideoDownloaderController controller;

  CookieStore get _cookies => controller.cookies;

  static bool get _canSignIn => Desktop.webViewsSupported;

  void _say(BuildContext context, String text) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _import(BuildContext context) async {
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: 'Choose a cookies.txt file',
      type: Platform.isAndroid ? FileType.any : FileType.custom,
      allowedExtensions: Platform.isAndroid ? null : const ['txt'],
    );
    final path = picked?.files.single.path;
    if (path == null || !context.mounted) return;
    try {
      final result = await controller.importCookies(File(path));
      if (!context.mounted) return;
      final notes = [
        if (result.invalidLines > 0) '${result.invalidLines} lines skipped',
        if (result.expired > 0) '${result.expired} expired',
      ];
      _say(context, 'Imported ${result.summary}${notes.isEmpty ? '' : ' (${notes.join(', ')})'}');
    } on CookieFormatException catch (e) {
      if (context.mounted) _say(context, e.message);
    } catch (e) {
      if (context.mounted) _say(context, "Couldn't import the file: $e");
    }
  }

  Future<void> _removeImported(BuildContext context) async {
    final ok = await _confirm(
      context,
      title: 'Remove the imported cookies?',
      message: 'Folders forgets the cookies from ${_cookies.imported?.fileName}. '
          'The file itself stays where it is.',
      action: 'Remove',
    );
    if (ok) await controller.removeImportedCookies();
  }

  Future<void> _signIn(BuildContext context, CookieSite site) async {
    final found = await showSiteLogin(
      context,
      site: site,
      userAgent: controller.settings.effectiveUserAgent,
    );
    if (found == null || !context.mounted) return;
    try {
      final count = await controller.saveSignIn(site, found);
      if (!context.mounted) return;
      final status = _cookies.status(site);
      _say(
        context,
        count == 0
            ? 'No cookies for ${site.domain} were found.'
            : status.state == SiteState.signedIn || site.loginCookies.isEmpty
                ? 'Saved ${site.name}\'s cookies ($count).'
                : 'Saved $count cookies, but ${site.name} doesn\'t look signed in.',
      );
    } catch (e) {
      _say(context, "Couldn't save the cookies: $e");
    }
  }

  Future<void> _paste(BuildContext context, CookieSite site) async {
    final count = await showPasteCookiesDialog(
      context,
      site: site,
      onSave: (text) => controller.pasteCookies(site, text),
    );
    if (count != null && context.mounted) _say(context, 'Saved $count cookies for ${site.name}.');
  }

  Future<void> _signOut(BuildContext context, CookieSite site) async {
    final ok = await _confirm(
      context,
      title: 'Sign out of ${site.name}?',
      message: 'Folders deletes its ${site.domain} cookies. Downloads from '
          '${site.name} that need a sign-in stop working until you sign in again.',
      action: 'Sign out',
    );
    if (!ok) return;
    final fromLogin = _cookies.cookiesFor(site)?.source == CookieSource.login;
    await controller.signOut(site);
    if (fromLogin && _canSignIn) await clearWebViewCookies(site);
  }

  Future<void> _removeSite(BuildContext context, CookieSite site) async {
    final fromLogin = _cookies.cookiesFor(site)?.source == CookieSource.login;
    await controller.removeCookieSite(site);
    if (fromLogin && _canSignIn) await clearWebViewCookies(site);
  }

  Future<void> _addSite(BuildContext context) async {
    final site = await showAddCookieSiteDialog(context, _cookies.addableSites);
    if (site == null || !context.mounted) return;
    await controller.addCookieSite(site);
    if (!context.mounted) return;
    if (_canSignIn) {
      await _signIn(context, site);
    } else {
      await _paste(context, site);
    }
  }

  @override
  Widget build(BuildContext context) {
    final imported = _cookies.imported;
    final rows = <Widget>[
      ListTile(
        leading: const Icon(LucideIcons.fileText),
        title: const Text('Cookie file'),
        subtitle: Text(
          imported == null
              ? 'Not imported'
              : '${imported.summary}\n${imported.fileName}, imported '
                  '${DateFormat('d MMM y').format(imported.importedAt)}',
        ),
        isThreeLine: imported != null,
        trailing: imported == null
            ? OutlinedButton.icon(
                onPressed: () => _import(context),
                icon: const Icon(LucideIcons.fileUp, size: 16),
                label: const Text('Import'),
                style: _buttonStyle,
              )
            : MenuIconButton<String>(
                tooltip: 'Cookie file',
                onSelected: (v) => v == 'replace' ? _import(context) : _removeImported(context),
                itemBuilder: (_) => [
                  menuItem(value: 'replace', icon: LucideIcons.fileUp, label: 'Import another file'),
                  menuItem(
                    value: 'remove',
                    icon: LucideIcons.trash2,
                    label: 'Remove the imported cookies',
                    destructive: true,
                  ),
                ],
              ),
      ),
      for (final site in _cookies.sites) _siteTile(context, site),
      ListTile(
        leading: const Icon(LucideIcons.plus),
        title: const Text('Add a site'),
        subtitle: const Text('Instagram, X, Facebook, TikTok or any other site'),
        onTap: () => _addSite(context),
      ),
      if (!_canSignIn)
        const ListTile(
          leading: Icon(LucideIcons.info),
          title: Text('No sign-in page here'),
          subtitle: Text(
            "Folders can't show web pages on Linux. Import a cookie file or "
            'paste cookies for a site instead.',
          ),
        ),
      ListTile(
        leading: const Icon(LucideIcons.circleHelp),
        title: const Text('How to use cookies?'),
        onTap: () => showCookieHelp(context),
      ),
    ];
    return SurfaceCard(
      padding: const EdgeInsets.symmetric(vertical: 4),
      clip: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            rows[i],
          ],
        ],
      ),
    );
  }

  Widget _siteTile(BuildContext context, CookieSite site) {
    final status = _cookies.status(site);
    final tone = switch (status.state) {
      SiteState.signedIn => Tone.success,
      SiteState.expired => Tone.warning,
      _ => Tone.neutral,
    };
    return ListTile(
      leading: Icon(
        status.state == SiteState.signedIn ? LucideIcons.userCheck : LucideIcons.globe,
        color: tone == Tone.neutral ? null : context.toneColor(tone),
      ),
      title: Text(site.name),
      subtitle: Text(status.label),
      onTap: () => _canSignIn ? _signIn(context, site) : _paste(context, site),
      trailing: MenuIconButton<String>(
        tooltip: site.name,
        onSelected: (action) => switch (action) {
          'signIn' => _signIn(context, site),
          'paste' => _paste(context, site),
          'signOut' => _signOut(context, site),
          _ => _removeSite(context, site),
        },
        itemBuilder: (_) => [
          if (_canSignIn) menuItem(value: 'signIn', icon: LucideIcons.logIn, label: 'Sign in'),
          menuItem(value: 'paste', icon: LucideIcons.clipboardPaste, label: 'Paste cookies'),
          if (status.hasOwnCookies)
            menuItem(value: 'signOut', icon: LucideIcons.logOut, label: 'Sign out', destructive: true),
          if (!site.builtIn)
            menuItem(value: 'remove', icon: LucideIcons.trash2, label: 'Remove this site', destructive: true),
        ],
      ),
    );
  }

  static final _buttonStyle = OutlinedButton.styleFrom(
    minimumSize: const Size(0, 36),
    padding: const EdgeInsets.symmetric(horizontal: 12),
  );
}

Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String message,
  required String action,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        OutlinedButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: context.colors.destructive,
            foregroundColor: context.colors.destructiveForeground,
          ),
          onPressed: () => Navigator.pop(context, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// Asks for cookies for [site] (a Cookie header or cookies.txt text) and
/// saves them with [onSave], which throws [CookieFormatException] when the
/// text isn't cookies. Returns how many were saved, or null.
Future<int?> showPasteCookiesDialog(
  BuildContext context, {
  required CookieSite site,
  required Future<int> Function(String text) onSave,
}) =>
    AppSheet.show<int>(context, child: _PasteCookies(site: site, onSave: onSave));

class _PasteCookies extends StatefulWidget {
  const _PasteCookies({required this.site, required this.onSave});

  final CookieSite site;
  final Future<int> Function(String text) onSave;

  @override
  State<_PasteCookies> createState() => _PasteCookiesState();
}

class _PasteCookiesState extends State<_PasteCookies> {
  final _text = TextEditingController();
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final count = await widget.onSave(_text.text);
      if (!mounted) return;
      if (count == 0) {
        setState(() => _error = 'None of these cookies are for ${widget.site.domain}.');
      } else {
        Navigator.pop(context, count);
        return;
      }
    } on CookieFormatException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = "Couldn't save the cookies: $e");
    }
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(LucideIcons.clipboardPaste, size: 20),
            const SizedBox(width: 10),
            Expanded(child: Text('Cookies for ${widget.site.name}', style: text.titleMedium)),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Paste the Cookie header your browser sends to ${widget.site.domain} '
          '(name=value; name2=value2), or the text of a cookies.txt file. '
          'They replace the cookies saved for this site.',
          style: text.bodySmall,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _text,
          autofocus: true,
          autocorrect: false,
          enableSuggestions: false,
          minLines: 4,
          maxLines: 8,
          keyboardType: TextInputType.multiline,
          style: CodeFont.style(fontSize: 12, color: context.colors.foreground),
          decoration: InputDecoration(
            hintText: 'SID=…; HSID=…',
            errorText: _error,
            errorMaxLines: 3,
          ),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            OutlinedButton(
              onPressed: _saving ? null : () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: const Icon(LucideIcons.save, size: 16),
              label: const Text('Save'),
            ),
          ],
        ),
      ],
    );
  }
}

/// Picks a preset site or one from a link the user types.
Future<CookieSite?> showAddCookieSiteDialog(BuildContext context, List<CookieSite> presets) =>
    AppSheet.show<CookieSite>(context, child: _AddSite(presets: presets));

class _AddSite extends StatefulWidget {
  const _AddSite({required this.presets});

  final List<CookieSite> presets;

  @override
  State<_AddSite> createState() => _AddSiteState();
}

class _AddSiteState extends State<_AddSite> {
  final _link = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  void _addLink() {
    final site = CookieSite.forUrl(_link.text);
    if (site == null) {
      setState(() => _error = 'Type a site address, like vimeo.com or a link to its sign-in page.');
      return;
    }
    Navigator.pop(context, site);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(LucideIcons.plus, size: 20),
            const SizedBox(width: 10),
            Expanded(child: Text('Add a site', style: text.titleMedium)),
          ],
        ),
        const SizedBox(height: 12),
        for (final site in widget.presets)
          ListRow(
            leading: const IconBox(LucideIcons.globe, size: 32),
            title: site.name,
            subtitle: site.domain,
            onTap: () => Navigator.pop(context, site),
          ),
        if (widget.presets.isNotEmpty) const SizedBox(height: 12),
        TextField(
          controller: _link,
          autocorrect: false,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            labelText: 'Another site',
            hintText: 'vimeo.com or a link to its sign-in page',
            prefixIcon: const Icon(LucideIcons.link, size: 16),
            errorText: _error,
            errorMaxLines: 2,
          ),
          onSubmitted: (_) => _addLink(),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _addLink,
              icon: const Icon(LucideIcons.plus, size: 16),
              label: const Text('Add'),
            ),
          ],
        ),
      ],
    );
  }
}

/// Why and how to give the downloader cookies.
Future<void> showCookieHelp(BuildContext context) => AppSheet.show<void>(
      context,
      style: SheetStyle.side,
      child: Builder(builder: (context) {
        final text = Theme.of(context).textTheme;
        Widget part(IconData icon, String title, String body) => Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(icon, size: 18, color: context.colors.mutedForeground),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: text.titleSmall),
                        const SizedBox(height: 4),
                        Text(body, style: text.bodySmall?.copyWith(height: 1.45)),
                      ],
                    ),
                  ),
                ],
              ),
            );
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('How to use cookies?', style: text.titleMedium),
            const SizedBox(height: 16),
            part(
              LucideIcons.lock,
              'Why',
              'Some videos need you to be signed in: age-restricted videos, '
                  "members-only videos, private ones you're allowed to see, or "
                  'sites that show nothing without an account. Cookies let '
                  'yt-dlp download them as you.',
            ),
            if (Desktop.webViewsSupported)
              part(
                LucideIcons.logIn,
                'Sign in here',
                'Tap a site and sign in on its page, then tap Done. Folders '
                    "keeps that site's cookies. Google sometimes refuses to sign "
                    'in inside apps; use a cookie file for YouTube then.',
              ),
            part(
              LucideIcons.fileUp,
              'Or import a cookie file',
              'In a browser where you are signed in, install an extension that '
                  'exports cookies in Netscape format (cookies.txt), export them '
                  'for the site, and import the file here. One file can hold '
                  'several sites.',
            ),
            part(
              LucideIcons.clipboardPaste,
              'Or paste them',
              "Copy the Cookie header from your browser's developer tools "
                  '(Network, a request to the site, Request headers) and paste '
                  'it under Paste cookies for that site.',
            ),
            part(
              LucideIcons.shieldCheck,
              'Keep them safe',
              'Cookies are as sensitive as a password: anyone who has them can '
                  "use your account. Folders keeps them in its own storage on "
                  'this device, sends them only to yt-dlp and never writes them '
                  "to its log. Don't share a cookie file, and sign out here when "
                  "you don't need them. Signing out in the browser ends them too.",
            ),
          ],
        );
      }),
    );
