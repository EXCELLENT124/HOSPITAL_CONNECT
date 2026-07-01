import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'backend_config.dart';
import 'supabase_service.dart';

enum UserRole { hospital, lawyer }

enum Palette { ocean, coral, violet }

class Profile {
  Profile(
      {required this.name,
      required this.email,
      required this.role,
      required this.organisation,
      required this.city,
      this.verified = false});
  final String name, email, organisation, city;
  final UserRole role;
  final bool verified;
  Map<String, dynamic> toJson() => {
        'name': name,
        'email': email,
        'role': role.name,
        'organisation': organisation,
        'city': city,
        'verified': verified
      };
  factory Profile.fromJson(Map<String, dynamic> j) => Profile(
      name: j['name'],
      email: j['email'],
      role: UserRole.values.byName(j['role']),
      organisation: j['organisation'],
      city: j['city'],
      verified: j['verified'] ?? false);
}

class RafCase {
  RafCase(
      {required this.id,
      required this.patient,
      required this.hospital,
      required this.city,
      required this.status,
      required this.created,
      this.lawyer,
      this.lawyerId,
      List<String>? documents,
      List<ChatMessage>? messages,
      List<TimelineEvent>? timeline})
      : documents = documents ?? [],
        messages = messages ?? [],
        timeline = timeline ?? [];
  final String id, patient, hospital, city;
  String status;
  String? lawyer;
  String? lawyerId;
  final DateTime created;
  final List<String> documents;
  final List<ChatMessage> messages;
  final List<TimelineEvent> timeline;

  int get readiness {
    var score = 20;
    if (lawyer != null) score += 25;
    if (documents.isNotEmpty) score += 25;
    if (messages.isNotEmpty) score += 10;
    if (status == 'Legal review' || status == 'Submitted to RAF') score += 20;
    return score.clamp(0, 100);
  }

  int get daysOpen => DateTime.now().difference(created).inDays.clamp(0, 9999);

  int get attentionScore {
    if (status == 'Submitted to RAF') return 0;
    var score = 100 - readiness;
    score += daysOpen.clamp(0, 30);
    if (lawyer == null) score += 20;
    if (documents.isEmpty) score += 15;
    return score.clamp(0, 100);
  }

  Map<String, bool> get evidenceChecklist {
    final names = documents.join(' ').toLowerCase();
    bool hasAny(List<String> words) => words.any(names.contains);
    return {
      'Identity document': hasAny(['identity', ' id ', 'id.', 'passport']),
      'Medical records':
          hasAny(['medical', 'hospital', 'clinical', 'doctor', 'report']),
      'Accident evidence':
          hasAny(['accident', 'police', 'crash', 'scene', 'affidavit']),
      'Consent or mandate':
          hasAny(['consent', 'mandate', 'authority', 'authorisation']),
      'Income evidence':
          hasAny(['income', 'payslip', 'salary', 'employment', 'earnings']),
    };
  }

  List<String> get suggestedMissingEvidence => evidenceChecklist.entries
      .where((entry) => !entry.value)
      .map((entry) => entry.key)
      .toList();

  int get evidencePercent {
    final complete = evidenceChecklist.values.where((value) => value).length;
    return (complete / evidenceChecklist.length * 100).round();
  }

  String get urgency {
    final age = DateTime.now().difference(created).inDays;
    if (status == 'Submitted to RAF') return 'Filed';
    if (lawyer == null && age >= 2) return 'High attention';
    if (documents.isEmpty) return 'Needs records';
    if (lawyer == null) return 'Needs lawyer';
    return 'On track';
  }

  String get nextAction {
    if (documents.isEmpty) {
      return 'Attach accident, hospital, or medical records.';
    }
    if (lawyer == null) return 'Assign the best matching RAF lawyer.';
    if (messages.isEmpty) return 'Send the first case handover message.';
    if (status != 'Submitted to RAF') {
      return 'Review readiness and move toward RAF submission.';
    }
    return 'Monitor response and keep documents updated.';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'patient': patient,
        'hospital': hospital,
        'city': city,
        'status': status,
        'lawyer': lawyer,
        'lawyerId': lawyerId,
        'created': created.toIso8601String(),
        'documents': documents,
        'messages': messages.map((e) => e.toJson()).toList(),
        'timeline': timeline.map((e) => e.toJson()).toList()
      };
  factory RafCase.fromJson(Map<String, dynamic> j) => RafCase(
      id: j['id'],
      patient: j['patient'],
      hospital: j['hospital'],
      city: j['city'],
      status: j['status'],
      lawyer: j['lawyer'],
      lawyerId: j['lawyerId'],
      created: DateTime.parse(j['created']),
      documents: List<String>.from(j['documents'] ?? []),
      messages: (j['messages'] as List? ?? [])
          .map((e) => ChatMessage.fromJson(e))
          .toList(),
      timeline: (j['timeline'] as List? ?? [])
          .map((e) => TimelineEvent.fromJson(e))
          .toList());
}

class TimelineEvent {
  TimelineEvent(this.icon, this.title, this.detail, this.time);
  final String icon, title, detail;
  final DateTime time;
  Map<String, dynamic> toJson() => {
        'icon': icon,
        'title': title,
        'detail': detail,
        'time': time.toIso8601String()
      };
  factory TimelineEvent.fromJson(Map<String, dynamic> j) => TimelineEvent(
      j['icon'], j['title'], j['detail'], DateTime.parse(j['time']));
}

class ChatMessage {
  ChatMessage(this.sender, this.text, this.time);
  final String sender, text;
  final DateTime time;
  Map<String, dynamic> toJson() =>
      {'sender': sender, 'text': text, 'time': time.toIso8601String()};
  factory ChatMessage.fromJson(Map<String, dynamic> j) =>
      ChatMessage(j['sender'], j['text'], DateTime.parse(j['time']));
}

class LawyerInfo {
  const LawyerInfo(
      this.name, this.city, this.experience, this.available, this.success,
      {this.organisationId});
  final String name, city;
  final int experience;
  final bool available;
  final double success;
  final String? organisationId;
}

class AppStore extends ChangeNotifier {
  static const storage = FlutterSecureStorage();
  Profile? profile;
  bool ready = false;
  bool syncing = false;
  Palette palette = Palette.ocean;
  bool dark = false;
  bool privacyShield = false;
  final cases = <RafCase>[];
  final notices = <String>[];
  final followUps = <String, DateTime>{};
  final lawyers = <LawyerInfo>[
    LawyerInfo('Adv. Naledi Jacobs', 'Johannesburg', 12, true, .94),
    LawyerInfo('Mpho Khumalo Attorneys', 'Sandton', 16, true, .91),
    LawyerInfo('Ayesha Pillay', 'Pretoria', 9, false, .89),
    LawyerInfo('Dlamini RAF Law', 'Durban', 14, true, .92),
    LawyerInfo('Cape Justice Partners', 'Cape Town', 11, true, .90),
  ];

  Future<void> initialise() async {
    final raw = await storage.read(key: 'health_connect_state');
    if (raw != null) {
      try {
        final j = jsonDecode(raw);
        if (j['profile'] != null) profile = Profile.fromJson(j['profile']);
        cases.addAll(
            (j['cases'] as List? ?? []).map((e) => RafCase.fromJson(e)));
        notices.addAll(List<String>.from(j['notices'] ?? []));
        followUps.addAll((j['followUps'] as Map<String, dynamic>? ?? {}).map(
            (key, value) => MapEntry(key, DateTime.parse(value as String))));
        palette = Palette.values.byName(j['palette'] ?? 'ocean');
        dark = j['dark'] ?? false;
        privacyShield = j['privacyShield'] ?? false;
      } catch (_) {
        await storage.delete(key: 'health_connect_state');
      }
    }
    if (BackendConfig.enabled &&
        SupabaseService.client.auth.currentUser != null) {
      await loadRemote(
          roleFallback: profile?.role ?? UserRole.hospital, fallback: profile);
    }
    ready = true;
    notifyListeners();
  }

  Future<void> persist() async {
    await storage.write(
        key: 'health_connect_state',
        value: jsonEncode({
          'profile': profile?.toJson(),
          'cases': cases.map((e) => e.toJson()).toList(),
          'notices': notices,
          'followUps': followUps
              .map((key, value) => MapEntry(key, value.toIso8601String())),
          'palette': palette.name,
          'dark': dark,
          'privacyShield': privacyShield,
        }));
  }

  Future<void> signIn(String email, String password, UserRole role) async {
    if (BackendConfig.enabled) {
      await SupabaseService.signIn(email: email, password: password);
      await loadRemote(roleFallback: role);
      notices.insert(0, 'Signed in securely as ${profile!.organisation}');
      await persist();
      notifyListeners();
      return;
    }
    profile = Profile(
        name: role == UserRole.hospital ? 'Nomsa Mthembu' : 'Naledi Jacobs',
        email: email,
        role: role,
        organisation: role == UserRole.hospital
            ? 'Ubuntu Regional Hospital'
            : 'Jacobs Legal Care',
        city: 'Johannesburg');
    notices.insert(0, 'Signed in securely as ${profile!.organisation}');
    await persist();
    notifyListeners();
  }

  Future<void> register(Profile value, String password) async {
    if (BackendConfig.enabled) {
      await SupabaseService.register(
          name: value.name,
          email: value.email,
          password: password,
          role: value.role.name,
          organisation: value.organisation,
          city: value.city);
      await loadRemote(roleFallback: value.role, fallback: value);
      notices.insert(0, '${profile!.organisation} registration submitted');
      await persist();
      notifyListeners();
      return;
    }
    profile = value;
    notices.insert(0, '${value.organisation} registration submitted');
    await persist();
    notifyListeners();
  }

  Future<void> signOut() async {
    if (BackendConfig.enabled) await SupabaseService.signOut();
    profile = null;
    await persist();
    notifyListeners();
  }

  Future<void> refreshRemote() async {
    if (!BackendConfig.enabled || profile == null || syncing) return;
    syncing = true;
    notifyListeners();
    try {
      await loadRemote(roleFallback: profile!.role, fallback: profile);
      notices.insert(0, 'Synced latest Supabase data');
      await persist();
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  Future<void> addCase(RafCase value) async {
    value.timeline.insert(
        0,
        TimelineEvent(
            'case',
            'Case opened',
            '${value.patient} RAF matter created in ${value.city}',
            DateTime.now()));
    cases.insert(0, value);
    notices.insert(0, 'Case ${value.id} created');
    if (BackendConfig.enabled) {
      await SupabaseService.saveCase(
          id: value.id,
          patientName: value.patient,
          city: value.city,
          status: value.status,
          lawyerName: value.lawyer,
          lawyerId: value.lawyerId);
      await loadRemote(roleFallback: profile!.role);
    }
    await persist();
    notifyListeners();
  }

  Future<void> updateCase(RafCase value, String notice) async {
    value.timeline.insert(
        0, TimelineEvent('update', notice, value.status, DateTime.now()));
    notices.insert(0, notice);
    if (BackendConfig.enabled) {
      await SupabaseService.saveCase(
          id: value.id,
          patientName: value.patient,
          city: value.city,
          status: value.status,
          lawyerName: value.lawyer,
          lawyerId: value.lawyerId);
      await loadRemote(roleFallback: profile!.role);
    }
    await persist();
    notifyListeners();
  }

  Future<void> theme({Palette? value, bool? isDark}) async {
    if (value != null) palette = value;
    if (isDark != null) dark = isDark;
    await persist();
    notifyListeners();
  }

  String patientLabel(String name) =>
      privacyShield ? 'Protected patient' : name;

  Future<void> togglePrivacyShield() async {
    privacyShield = !privacyShield;
    notices.insert(0,
        privacyShield ? 'Privacy shield enabled' : 'Privacy shield disabled');
    await persist();
    notifyListeners();
  }

  Future<void> setFollowUp(RafCase item, DateTime? date) async {
    if (date == null) {
      followUps.remove(item.id);
      notices.insert(0, 'Follow-up cleared for ${item.id}');
    } else {
      followUps[item.id] = DateTime(date.year, date.month, date.day);
      notices.insert(0, 'Follow-up scheduled for ${item.id}');
    }
    await persist();
    notifyListeners();
  }

  bool followUpOverdue(RafCase item) {
    final date = followUps[item.id];
    if (date == null) return false;
    final today = DateTime.now();
    return date.isBefore(DateTime(today.year, today.month, today.day));
  }

  int operationalScore(RafCase item) =>
      (item.attentionScore + (followUpOverdue(item) ? 25 : 0)).clamp(0, 100);

  Future<void> loadRemote(
      {required UserRole roleFallback, Profile? fallback}) async {
    if (!BackendConfig.enabled) return;

    final organisation = await SupabaseService.currentOrganisation();
    if (organisation != null) {
      final roleName = organisation['type'] as String? ?? roleFallback.name;
      profile = Profile(
        name: (organisation['display_name'] as String?) ??
            fallback?.name ??
            'Health Connect user',
        email: (organisation['email'] as String?) ?? fallback?.email ?? '',
        role: UserRole.values.byName(roleName),
        organisation: organisation['name'] as String,
        city: organisation['city'] as String,
        verified: organisation['verified'] as bool? ?? false,
      );
    } else if (fallback != null) {
      profile = fallback;
    }

    final remoteLawyers = await SupabaseService.fetchLawyers();
    lawyers
      ..clear()
      ..addAll(remoteLawyers.map((row) => LawyerInfo(
            row['name'] as String,
            row['city'] as String,
            10,
            true,
            .90,
            organisationId: row['id'] as String,
          )));

    final remoteCases = await SupabaseService.fetchCases();
    cases
      ..clear()
      ..addAll(remoteCases.map((row) {
        final hospital = row['hospital'];
        final documents = List<String>.from(row['documents'] as List? ?? []);
        final messages = (row['messages'] as List? ?? [])
            .map((message) => ChatMessage(
                  'Case team',
                  message['body'] as String,
                  DateTime.parse(message['created_at'] as String),
                ))
            .toList();
        final created = DateTime.parse(row['created_at'] as String);
        final lawyerName = row['assigned_lawyer_name'] as String?;
        return RafCase(
          id: row['id'] as String,
          patient: row['patient_name'] as String,
          hospital: hospital is Map
              ? hospital['name'] as String
              : profile?.organisation ?? 'Hospital',
          city: row['accident_city'] as String,
          status: row['status'] as String,
          lawyer: lawyerName,
          lawyerId: row['assigned_lawyer_id'] as String?,
          created: created,
          documents: documents,
          messages: messages,
          timeline: [
            if (lawyerName != null)
              TimelineEvent('lawyer', 'Lawyer assigned', lawyerName, created),
            ...documents.map((name) =>
                TimelineEvent('document', 'Document attached', name, created)),
            ...messages.map((message) => TimelineEvent(
                'message', 'Message added', message.text, message.time)),
            TimelineEvent(
                'case',
                'Case opened',
                '${row['patient_name']} RAF matter created in ${row['accident_city']}',
                created),
          ]..sort((a, b) => b.time.compareTo(a.time)),
        );
      }));
  }

  int match(LawyerInfo lawyer, String city) {
    var score = 55;
    if (lawyer.city.toLowerCase() == city.toLowerCase()) score += 25;
    if (lawyer.available) score += 8;
    score += (lawyer.experience.clamp(0, 15) / 3).round();
    score += (lawyer.success * 7).round();
    score -= lawyerCaseload(lawyer) * 3;
    return score.clamp(0, 99);
  }

  int lawyerCaseload(LawyerInfo lawyer) => cases
      .where((item) =>
          item.status != 'Submitted to RAF' &&
          (item.lawyerId == lawyer.organisationId ||
              item.lawyer?.toLowerCase() == lawyer.name.toLowerCase()))
      .length;
}

class HealthConnectApp extends StatefulWidget {
  const HealthConnectApp({super.key});
  @override
  State<HealthConnectApp> createState() => _HealthConnectAppState();
}

class _HealthConnectAppState extends State<HealthConnectApp> {
  final store = AppStore();
  @override
  void initState() {
    super.initState();
    store.initialise();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: store,
        builder: (context, _) {
          final seed = switch (store.palette) {
            Palette.ocean => const Color(0xFF078A91),
            Palette.coral => const Color(0xFFE65C4F),
            Palette.violet => const Color(0xFF7057B8)
          };
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            title: 'Health Connect',
            themeMode: store.dark ? ThemeMode.dark : ThemeMode.light,
            themeAnimationDuration: const Duration(milliseconds: 450),
            theme: _theme(seed, Brightness.light),
            darkTheme: _theme(seed, Brightness.dark),
            home: !store.ready
                ? const Scaffold(
                    body: Center(child: CircularProgressIndicator()))
                : store.profile == null
                    ? AuthScreen(store)
                    : HomeScreen(store),
          );
        },
      );
  ThemeData _theme(Color seed, Brightness brightness) {
    final scheme =
        ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
    return ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: brightness == Brightness.light
            ? const Color(0xFFF4F7F8)
            : const Color(0xFF101416),
        cardTheme: CardThemeData(
            elevation: 0,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(22))),
        inputDecorationTheme: InputDecorationTheme(
            filled: true,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none)));
  }
}

class AuthScreen extends StatefulWidget {
  const AuthScreen(this.store, {super.key});
  final AppStore store;
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool register = false, loading = false;
  UserRole role = UserRole.hospital;
  final name = TextEditingController(),
      email = TextEditingController(),
      password = TextEditingController(),
      organisation = TextEditingController(),
      city = TextEditingController(text: 'Johannesburg');
  final form = GlobalKey<FormState>();
  @override
  Widget build(BuildContext context) => Scaffold(
      body: Center(
          child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 500),
                  child: Card(
                      child: Padding(
                          padding: const EdgeInsets.all(28),
                          child: Form(
                              key: form,
                              child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    const Align(
                                        alignment: Alignment.centerLeft,
                                        child: BrandMark(size: 64)),
                                    const SizedBox(height: 18),
                                    Text(
                                        register
                                            ? 'Join Health Connect'
                                            : 'Welcome back',
                                        style: const TextStyle(
                                            fontSize: 28,
                                            fontWeight: FontWeight.w900)),
                                    Text(
                                        register
                                            ? 'Register your verified care organisation.'
                                            : 'Secure access for hospitals and legal teams.',
                                        style: const TextStyle(
                                            color: Colors.grey)),
                                    const SizedBox(height: 20),
                                    SegmentedButton<UserRole>(
                                        segments: const [
                                          ButtonSegment(
                                              value: UserRole.hospital,
                                              icon: Icon(Icons.local_hospital),
                                              label: Text('Hospital')),
                                          ButtonSegment(
                                              value: UserRole.lawyer,
                                              icon: Icon(Icons.balance),
                                              label: Text('Lawyer'))
                                        ],
                                        selected: {
                                          role
                                        },
                                        onSelectionChanged: (s) =>
                                            setState(() => role = s.first)),
                                    if (register) ...[
                                      const SizedBox(height: 14),
                                      TextFormField(
                                          controller: name,
                                          decoration: const InputDecoration(
                                              labelText: 'Full name'),
                                          validator: required),
                                      const SizedBox(height: 12),
                                      TextFormField(
                                          controller: organisation,
                                          decoration: InputDecoration(
                                              labelText:
                                                  role == UserRole.hospital
                                                      ? 'Hospital name'
                                                      : 'Legal practice'),
                                          validator: required),
                                      const SizedBox(height: 12),
                                      TextFormField(
                                          controller: city,
                                          decoration: const InputDecoration(
                                              labelText:
                                                  'City / service location'),
                                          validator: required)
                                    ],
                                    const SizedBox(height: 12),
                                    TextFormField(
                                        controller: email,
                                        keyboardType:
                                            TextInputType.emailAddress,
                                        decoration: const InputDecoration(
                                            labelText: 'Work email'),
                                        validator: (v) =>
                                            (v ?? '').contains('@')
                                                ? null
                                                : 'Enter a valid email'),
                                    const SizedBox(height: 12),
                                    TextFormField(
                                        controller: password,
                                        obscureText: true,
                                        decoration: const InputDecoration(
                                            labelText: 'Password'),
                                        validator: (v) => (v ?? '').length >= 6
                                            ? null
                                            : 'Use at least 6 characters'),
                                    const SizedBox(height: 20),
                                    FilledButton(
                                        onPressed: loading ? null : submit,
                                        child: Padding(
                                            padding: const EdgeInsets.all(12),
                                            child: Text(loading
                                                ? 'Please wait…'
                                                : register
                                                    ? 'Register organisation'
                                                    : 'Sign in'))),
                                    TextButton(
                                        onPressed: () => setState(
                                            () => register = !register),
                                        child: Text(register
                                            ? 'Already registered? Sign in'
                                            : 'New organisation? Register')),
                                    Text(
                                        BackendConfig.enabled
                                            ? 'Connected to Supabase secure backend.'
                                            : 'Local demo mode. Do not use real patient data yet.',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                            fontSize: 11, color: Colors.grey)),
                                  ]))))))));
  static String? required(String? v) =>
      (v ?? '').trim().isEmpty ? 'Required' : null;
  Future<void> submit() async {
    if (!form.currentState!.validate()) return;
    setState(() => loading = true);
    try {
      if (register) {
        await widget.store
            .register(
              Profile(
                name: name.text.trim(),
                email: email.text.trim(),
                role: role,
                organisation: organisation.text.trim(),
                city: city.text.trim(),
              ),
              password.text,
            )
            .timeout(const Duration(seconds: 25));
      } else {
        await widget.store
            .signIn(email.text.trim(), password.text, role)
            .timeout(const Duration(seconds: 25));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not complete request: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen(this.store, {super.key});
  final AppStore store;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int index = 0;
  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final pages = [
      Dashboard(widget.store),
      OperationsPage(widget.store),
      CasesPage(widget.store),
      LawyersPage(widget.store),
      NetworkPage(widget.store),
      MessagesPage(widget.store)
    ];
    const labels = [
      'Overview',
      'Operations',
      'RAF cases',
      'Lawyers',
      'Network',
      'Messages'
    ];
    const icons = [
      Icons.grid_view_rounded,
      Icons.radar_rounded,
      Icons.folder_copy_outlined,
      Icons.balance_rounded,
      Icons.domain_rounded,
      Icons.chat_bubble_outline
    ];
    return Scaffold(
        body: SafeArea(
            child: Row(children: [
          if (wide)
            NavigationRail(
                extended: MediaQuery.sizeOf(context).width >= 1200,
                selectedIndex: index,
                onDestinationSelected: (v) => setState(() => index = v),
                leading: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 18),
                    child: BrandMark(size: 50)),
                destinations: List.generate(
                    labels.length,
                    (i) => NavigationRailDestination(
                        icon: Icon(icons[i]), label: Text(labels[i])))),
          Expanded(
              child: Column(children: [
            Header(widget.store),
            Expanded(
                child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: pages[index]))
          ]))
        ])),
        bottomNavigationBar: wide
            ? null
            : NavigationBar(
                selectedIndex: index,
                onDestinationSelected: (v) => setState(() => index = v),
                destinations: List.generate(
                    labels.length,
                    (i) => NavigationDestination(
                        icon: Icon(icons[i]), label: labels[i]))),
        floatingActionButton: widget.store.profile!.role == UserRole.hospital
            ? FloatingActionButton.extended(
                onPressed: () => showDialog(
                    context: context,
                    builder: (_) => NewCaseDialog(widget.store)),
                icon: const Icon(Icons.add),
                label: const Text('New RAF case'))
            : null);
  }
}

class Header extends StatelessWidget {
  const Header(this.store, {super.key});
  final AppStore store;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.fromLTRB(22, 12, 18, 8),
      child: Row(children: [
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Health Connect',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
          Text(
              '${store.profile!.organisation} · ${store.profile!.role.name} · ${store.profile!.verified ? 'verified' : 'pending verification'}',
              style: const TextStyle(color: Colors.grey))
        ])),
        Badge(
            label: Text('${store.notices.length}'),
            child: IconButton(
                onPressed: () => showModalBottomSheet(
                    context: context, builder: (_) => Notices(store)),
                icon: const Icon(Icons.notifications_outlined))),
        if (BackendConfig.enabled)
          IconButton(
              tooltip: 'Sync latest data',
              onPressed: store.syncing
                  ? null
                  : () async {
                      try {
                        await store.refreshRemote();
                      } catch (error) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text('Could not sync: $error')));
                        }
                      }
                    },
              icon: store.syncing
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.sync_rounded)),
        PopupMenuButton<Palette>(
            icon: const Icon(Icons.palette_outlined),
            onSelected: (v) => store.theme(value: v),
            itemBuilder: (_) => const [
                  PopupMenuItem(
                      value: Palette.ocean, child: Text('Ocean teal')),
                  PopupMenuItem(
                      value: Palette.coral, child: Text('Sunrise coral')),
                  PopupMenuItem(
                      value: Palette.violet, child: Text('Ubuntu violet'))
                ]),
        IconButton(
            onPressed: () => store.theme(isDark: !store.dark),
            icon:
                Icon(store.dark ? Icons.light_mode : Icons.dark_mode_outlined)),
        IconButton(
            tooltip: store.privacyShield
                ? 'Reveal patient identities'
                : 'Mask patient identities',
            onPressed: store.togglePrivacyShield,
            icon: Icon(store.privacyShield
                ? Icons.visibility_off
                : Icons.privacy_tip_outlined),
            color: store.privacyShield
                ? Theme.of(context).colorScheme.primary
                : null),
        PopupMenuButton(
            icon: CircleAvatar(
                child: Text(store.profile!.name.substring(0, 1).toUpperCase())),
            itemBuilder: (_) => [
                  PopupMenuItem(
                      onTap: store.signOut,
                      child: const Row(children: [
                        Icon(Icons.logout),
                        SizedBox(width: 10),
                        Text('Sign out')
                      ]))
                ]),
      ]));
}

class Dashboard extends StatelessWidget {
  const Dashboard(this.store, {super.key});
  final AppStore store;
  @override
  Widget build(BuildContext context) =>
      AppList(key: const ValueKey('dashboard'), children: [
        Welcome(store.profile!),
        const SizedBox(height: 16),
        Wrap(spacing: 12, runSpacing: 12, children: [
          Metric(Icons.folder_open, '${store.cases.length}', 'Active cases'),
          Metric(
              Icons.task_alt,
              '${store.cases.where((e) => e.documents.isNotEmpty).length}',
              'With documents'),
          Metric(
              Icons.priority_high_rounded,
              '${store.cases.where((e) => e.urgency != 'On track' && e.urgency != 'Filed').length}',
              'Need action'),
          Metric(
              Icons.health_and_safety_outlined,
              store.cases.isEmpty
                  ? '0%'
                  : '${(store.cases.map((e) => e.readiness).reduce((a, b) => a + b) / store.cases.length).round()}%',
              'Avg readiness'),
          Metric(
              Icons.notification_important_outlined,
              '${store.cases.where(store.followUpOverdue).length}',
              'Overdue follow-ups')
        ]),
        const SectionTitle('Recent cases'),
        if (store.cases.isEmpty)
          const EmptyState(Icons.folder_open, 'No RAF cases yet',
              'Use “New RAF case” to create the first secure record.')
        else
          ...store.cases.take(3).map((e) => CaseCard(store, e)),
        const SectionTitle('Activity'),
        ...store.notices.take(4).map((e) => ListTile(
            leading: const CircleAvatar(child: Icon(Icons.notifications_none)),
            title: Text(e))),
      ]);
}

class OperationsPage extends StatelessWidget {
  const OperationsPage(this.store, {super.key});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final actionable = store.cases
        .where((item) => item.status != 'Submitted to RAF')
        .toList()
      ..sort((a, b) =>
          store.operationalScore(b).compareTo(store.operationalScore(a)));
    final uncoveredCities = store.cases
        .where((item) => item.lawyer == null)
        .map((item) => item.city)
        .where((city) => !store.lawyers
            .any((lawyer) => lawyer.available && lawyer.city == city))
        .toSet()
        .toList();
    final readyCount = store.cases.where((item) => item.readiness >= 80).length;

    return AppList(key: const ValueKey('operations'), children: [
      const Heading('RAF Operations Centre',
          'A live command view of priority work, case flow and network coverage.'),
      OperationsPulse(
          actionCount:
              actionable.where((item) => item.attentionScore >= 60).length,
          readyCount: readyCount,
          uncoveredCount: uncoveredCities.length),
      const SectionTitle('Priority action queue'),
      if (actionable.isEmpty)
        const EmptyState(Icons.task_alt, 'Action queue is clear',
            'All current matters have reached the submitted stage.')
      else
        ...actionable.take(5).map((item) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: ActionQueueCard(store, item))),
      const SectionTitle('Case flow'),
      CaseFlowBoard(store.cases),
      const SectionTitle('Follow-up planner'),
      FollowUpBoard(store),
      const SectionTitle('Network coverage radar'),
      if (uncoveredCities.isEmpty)
        const CoverageNotice(
            Icons.hub_outlined,
            'Coverage looks healthy',
            'Every unassigned case city has an available local lawyer match.',
            Colors.green)
      else
        CoverageNotice(
            Icons.location_off_outlined,
            '${uncoveredCities.length} coverage gap${uncoveredCities.length == 1 ? '' : 's'}',
            'No available same-city lawyer for: ${uncoveredCities.join(', ')}.',
            Colors.orange)
    ]);
  }
}

class OperationsPulse extends StatelessWidget {
  const OperationsPulse(
      {required this.actionCount,
      required this.readyCount,
      required this.uncoveredCount,
      super.key});
  final int actionCount, readyCount, uncoveredCount;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
            gradient: LinearGradient(colors: [
              colors.primaryContainer,
              colors.tertiaryContainer,
            ]),
            borderRadius: BorderRadius.circular(26)),
        child: Wrap(spacing: 28, runSpacing: 18, children: [
          const SizedBox(
              width: 230,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(Icons.radar_rounded),
                      SizedBox(width: 8),
                      Text('Command pulse',
                          style: TextStyle(
                              fontSize: 20, fontWeight: FontWeight.w900))
                    ]),
                    SizedBox(height: 6),
                    Text('Your live RAF workflow health at a glance.')
                  ])),
          PulseValue('$actionCount', 'High attention', Icons.priority_high),
          PulseValue('$readyCount', 'Ready ≥ 80%', Icons.verified_outlined),
          PulseValue(
              '$uncoveredCount', 'Coverage gaps', Icons.location_searching)
        ]));
  }
}

class PulseValue extends StatelessWidget {
  const PulseValue(this.value, this.label, this.icon, {super.key});
  final String value, label;
  final IconData icon;

  @override
  Widget build(BuildContext context) => SizedBox(
      width: 130,
      child: Row(children: [
        CircleAvatar(child: Icon(icon)),
        const SizedBox(width: 10),
        Expanded(
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Text(value,
                  style: const TextStyle(
                      fontSize: 22, fontWeight: FontWeight.w900)),
              Text(label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11))
            ]))
      ]));
}

class ActionQueueCard extends StatelessWidget {
  const ActionQueueCard(this.store, this.item, {super.key});
  final AppStore store;
  final RafCase item;

  @override
  Widget build(BuildContext context) {
    final color = CaseCard._urgencyColor(item.urgency);
    return Card(
        child: ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            leading: CircleAvatar(
                backgroundColor: color.withValues(alpha: .14),
                child: Text('${store.operationalScore(item)}',
                    style:
                        TextStyle(color: color, fontWeight: FontWeight.w900))),
            title: Text(store.patientLabel(item.patient),
                style: const TextStyle(fontWeight: FontWeight.w900)),
            subtitle: Text(
                '${item.nextAction}\n${item.id} · ${item.daysOpen} day${item.daysOpen == 1 ? '' : 's'} in workflow'),
            isThreeLine: true,
            trailing: FilledButton.tonalIcon(
                onPressed: () => showDialog(
                    context: context, builder: (_) => CaseDetails(store, item)),
                icon: const Icon(Icons.arrow_forward, size: 17),
                label: const Text('Open'))));
  }
}

class CaseFlowBoard extends StatelessWidget {
  const CaseFlowBoard(this.cases, {super.key});
  final List<RafCase> cases;

  @override
  Widget build(BuildContext context) {
    const stages = [
      'New referral',
      'Awaiting records',
      'Lawyer matching',
      'Legal review',
      'Submitted to RAF'
    ];
    return Wrap(
        spacing: 10,
        runSpacing: 10,
        children: stages.map((stage) {
          final count = cases.where((item) => item.status == stage).length;
          return Container(
              width: 180,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(18)),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('$count',
                        style: const TextStyle(
                            fontSize: 24, fontWeight: FontWeight.w900)),
                    Text(stage),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                        value: cases.isEmpty ? 0 : count / cases.length,
                        borderRadius: BorderRadius.circular(8))
                  ]));
        }).toList());
  }
}

class FollowUpBoard extends StatelessWidget {
  const FollowUpBoard(this.store, {super.key});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final scheduled = store.cases
        .where((item) => store.followUps.containsKey(item.id))
        .toList()
      ..sort(
          (a, b) => store.followUps[a.id]!.compareTo(store.followUps[b.id]!));
    if (scheduled.isEmpty) {
      return const CoverageNotice(
          Icons.event_available_outlined,
          'No follow-ups scheduled',
          'Open a case to schedule its next review date.',
          Colors.blue);
    }
    return Column(
        children: scheduled.take(5).map((item) {
      final date = store.followUps[item.id]!;
      final overdue = store.followUpOverdue(item);
      return ListTile(
          leading: CircleAvatar(
              backgroundColor:
                  (overdue ? Colors.red : Colors.blue).withValues(alpha: .14),
              child: Icon(overdue ? Icons.event_busy : Icons.event,
                  color: overdue ? Colors.red : Colors.blue)),
          title: Text('${item.id} · ${store.patientLabel(item.patient)}',
              style: const TextStyle(fontWeight: FontWeight.w800)),
          subtitle: Text(item.nextAction),
          trailing: Text('${overdue ? 'OVERDUE · ' : ''}${_shortDate(date)}',
              style: TextStyle(
                  color: overdue ? Colors.red : null,
                  fontWeight: FontWeight.w900)));
    }).toList());
  }

  static String _shortDate(DateTime date) =>
      '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
}

class CoverageNotice extends StatelessWidget {
  const CoverageNotice(this.icon, this.title, this.detail, this.color,
      {super.key});
  final IconData icon;
  final String title, detail;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
          color: color.withValues(alpha: .09),
          border: Border.all(color: color.withValues(alpha: .25)),
          borderRadius: BorderRadius.circular(20)),
      child: Row(children: [
        CircleAvatar(
            backgroundColor: color.withValues(alpha: .15),
            child: Icon(icon, color: color)),
        const SizedBox(width: 14),
        Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
              Text(detail)
            ]))
      ]));
}

class Welcome extends StatelessWidget {
  const Welcome(this.profile, {super.key});
  final Profile profile;
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(26),
            gradient: LinearGradient(colors: [c.primary, c.tertiary])),
        child: Row(children: [
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text('Hello, ${profile.name.split(' ').first}',
                    style: TextStyle(
                        color: c.onPrimary,
                        fontSize: 25,
                        fontWeight: FontWeight.w900)),
                const SizedBox(height: 6),
                Text(
                    profile.role == UserRole.hospital
                        ? 'Coordinate RAF care and legal referrals in one place.'
                        : 'Review referrals and support your clients securely.',
                    style: TextStyle(color: c.onPrimary.withValues(alpha: .85)))
              ])),
          const BrandMark(size: 82, translucent: true)
        ]));
  }
}

class Metric extends StatelessWidget {
  const Metric(this.icon, this.value, this.label, {super.key});
  final IconData icon;
  final String value, label;
  @override
  Widget build(BuildContext context) => SizedBox(
      width: 235,
      child: Card(
          child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(children: [
                CircleAvatar(child: Icon(icon)),
                const SizedBox(width: 14),
                Expanded(
                    child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(value,
                          style: const TextStyle(
                              fontSize: 24, fontWeight: FontWeight.w900)),
                      Text(label, maxLines: 2, overflow: TextOverflow.ellipsis)
                    ]))
              ]))));
}

class CasesPage extends StatefulWidget {
  const CasesPage(this.store, {super.key});
  final AppStore store;
  @override
  State<CasesPage> createState() => _CasesPageState();
}

class _CasesPageState extends State<CasesPage> {
  final search = TextEditingController();
  String selectedStatus = 'All';

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = search.text.trim().toLowerCase();
    final filtered = widget.store.cases.where((item) {
      final matchesStatus =
          selectedStatus == 'All' || item.status == selectedStatus;
      if (!matchesStatus) return false;
      if (query.isEmpty) return true;
      return [
        item.id,
        item.patient,
        item.hospital,
        item.city,
        item.status,
        item.lawyer ?? '',
      ].any((value) => value.toLowerCase().contains(query));
    }).toList();

    return AppList(key: const ValueKey('cases'), children: [
      const Heading('RAF cases',
          'Track the complete matter from admission to legal resolution.'),
      SearchBar(
          controller: search,
          leading: Icon(Icons.search),
          hintText: 'Search patient, reference, city, status or lawyer',
          trailing: [
            if (query.isNotEmpty)
              IconButton(
                  tooltip: 'Clear search',
                  onPressed: () => setState(search.clear),
                  icon: const Icon(Icons.close))
          ],
          onChanged: (_) => setState(() {})),
      const SizedBox(height: 12),
      SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
              children: [
            'All',
            'New referral',
            'Awaiting records',
            'Lawyer matching',
            'Legal review',
            'Submitted to RAF'
          ]
                  .map((status) => Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                            label: Text(status),
                            selected: selectedStatus == status,
                            onSelected: (_) =>
                                setState(() => selectedStatus = status)),
                      ))
                  .toList())),
      const SizedBox(height: 16),
      if (widget.store.cases.isEmpty)
        const EmptyState(Icons.folder_copy_outlined, 'No cases yet',
            'Hospital users can create a case with the button below.')
      else if (filtered.isEmpty)
        EmptyState(Icons.search_off, 'No matching cases',
            'No RAF cases match your search and status filter.')
      else
        ...filtered.map((e) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: CaseCard(widget.store, e)))
    ]);
  }
}

class CaseCard extends StatelessWidget {
  const CaseCard(this.store, this.item, {super.key});
  final AppStore store;
  final RafCase item;
  @override
  Widget build(BuildContext context) {
    final urgencyColor = _urgencyColor(item.urgency);
    return Card(
        child: InkWell(
            borderRadius: BorderRadius.circular(22),
            onTap: () => showDialog(
                context: context, builder: (_) => CaseDetails(store, item)),
            child: Padding(
                padding: const EdgeInsets.all(18),
                child: Row(children: [
                  Container(
                      width: 9,
                      height: 55,
                      decoration: BoxDecoration(
                          color: urgencyColor,
                          borderRadius: BorderRadius.circular(8))),
                  const SizedBox(width: 14),
                  Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text(store.patientLabel(item.patient),
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w900)),
                        Text('${item.id} · ${item.city}',
                            style: const TextStyle(color: Colors.grey)),
                        Text(item.lawyer ?? 'No lawyer assigned',
                            style: const TextStyle(fontSize: 12)),
                        const SizedBox(height: 8),
                        Row(children: [
                          Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                  color: urgencyColor.withValues(alpha: .12),
                                  borderRadius: BorderRadius.circular(20)),
                              child: Text(item.urgency,
                                  style: TextStyle(
                                      color: urgencyColor,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w800))),
                          const SizedBox(width: 10),
                          Text('${item.readiness}% ready',
                              style: const TextStyle(
                                  fontSize: 11, fontWeight: FontWeight.w700))
                        ])
                      ])),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Chip(label: Text(item.status)),
                    SizedBox(
                        width: 92,
                        child: LinearProgressIndicator(
                            value: item.readiness / 100,
                            color: urgencyColor,
                            borderRadius: BorderRadius.circular(8)))
                  ]),
                  const Icon(Icons.chevron_right)
                ]))));
  }

  static Color _urgencyColor(String urgency) => switch (urgency) {
        'High attention' => Colors.red,
        'Needs records' => Colors.orange,
        'Needs lawyer' => Colors.amber.shade800,
        'Filed' => Colors.blue,
        _ => Colors.green,
      };
}

class CaseDetails extends StatefulWidget {
  const CaseDetails(this.store, this.item, {super.key});
  final AppStore store;
  final RafCase item;
  @override
  State<CaseDetails> createState() => _CaseDetailsState();
}

class _CaseDetailsState extends State<CaseDetails> {
  @override
  Widget build(BuildContext context) => AlertDialog(
          title: Row(children: [
            Expanded(
                child: Text(widget.store.patientLabel(widget.item.patient))),
            if (widget.store.privacyShield)
              const Tooltip(
                  message: 'Patient identity is masked',
                  child: Icon(Icons.visibility_off, size: 20))
          ]),
          content: SizedBox(
              width: 560,
              child: SingleChildScrollView(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(
                        '${widget.item.id} · ${widget.item.hospital} · ${widget.item.city}'),
                    const SizedBox(height: 18),
                    SmartCaseInsight(widget.item),
                    const SizedBox(height: 18),
                    DropdownButtonFormField<String>(
                        initialValue: widget.item.status,
                        decoration:
                            const InputDecoration(labelText: 'Case status'),
                        items: [
                          'New referral',
                          'Awaiting records',
                          'Lawyer matching',
                          'Legal review',
                          'Submitted to RAF'
                        ]
                            .map((e) =>
                                DropdownMenuItem(value: e, child: Text(e)))
                            .toList(),
                        onChanged: (v) async {
                          if (v == null) return;
                          setState(() => widget.item.status = v);
                          await widget.store.updateCase(
                              widget.item, '${widget.item.id} moved to $v');
                        }),
                    const SizedBox(height: 12),
                    FollowUpControl(widget.store, widget.item, scheduleFollowUp,
                        clearFollowUp),
                    const SizedBox(height: 18),
                    const Text('Documents',
                        style: TextStyle(fontWeight: FontWeight.w900)),
                    const SizedBox(height: 8),
                    EvidencePackAssistant(widget.item),
                    const SizedBox(height: 8),
                    ...widget.item.documents.map((e) => ListTile(
                        leading: const Icon(Icons.description_outlined),
                        title: Text(e))),
                    OutlinedButton.icon(
                        onPressed: pickDocument,
                        icon: const Icon(Icons.upload_file),
                        label: const Text('Attach document')),
                    const SizedBox(height: 18),
                    const Text('Assigned lawyer',
                        style: TextStyle(fontWeight: FontWeight.w900)),
                    Text(widget.item.lawyer ?? 'Not assigned'),
                    const SizedBox(height: 18),
                    const Text('Case timeline',
                        style: TextStyle(fontWeight: FontWeight.w900)),
                    TimelineList(widget.item.timeline,
                        redactDetails: widget.store.privacyShield),
                  ]))),
          actions: [
            OutlinedButton.icon(
                onPressed: copySummary,
                icon: const Icon(Icons.content_copy),
                label: const Text('Copy summary')),
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'))
          ]);
  Future<void> pickDocument() async {
    final result =
        await FilePicker.platform.pickFiles(withData: BackendConfig.enabled);
    if (result != null) {
      final file = result.files.single;
      if (BackendConfig.enabled && file.bytes != null) {
        await SupabaseService.uploadDocument(
            caseId: widget.item.id, fileName: file.name, bytes: file.bytes!);
      }
      setState(() => widget.item.documents.add(file.name));
      await widget.store
          .updateCase(widget.item, 'Document added to ${widget.item.id}');
    }
  }

  Future<void> scheduleFollowUp() async {
    final existing = widget.store.followUps[widget.item.id];
    final now = DateTime.now();
    final selected = await showDatePicker(
        context: context,
        initialDate: existing ?? now.add(const Duration(days: 7)),
        firstDate: DateTime(2000),
        lastDate: DateTime(now.year + 5),
        helpText: 'Schedule case follow-up');
    if (selected != null) {
      await widget.store.setFollowUp(widget.item, selected);
      if (mounted) setState(() {});
    }
  }

  Future<void> clearFollowUp() async {
    await widget.store.setFollowUp(widget.item, null);
    if (mounted) setState(() {});
  }

  Future<void> copySummary() async {
    final item = widget.item;
    final summary = [
      'Health Connect RAF Case Summary',
      '',
      'Reference: ${item.id}',
      'Patient: ${widget.store.patientLabel(item.patient)}',
      'Hospital: ${item.hospital}',
      'Accident location: ${item.city}',
      'Current status: ${item.status}',
      'Assigned lawyer: ${item.lawyer ?? 'Not assigned'}',
      'Created: ${_dateLabel(item.created)}',
      '',
      'Documents:',
      if (item.documents.isEmpty)
        '- None attached yet'
      else
        ...item.documents.map((document) => '- $document'),
      '',
      'Suggested evidence review:',
      'Evidence detected: ${item.evidencePercent}%',
      if (item.suggestedMissingEvidence.isEmpty)
        '- No suggested gaps detected from filenames'
      else
        ...item.suggestedMissingEvidence
            .map((document) => '- Review: $document'),
      '',
      'Latest messages:',
      if (item.messages.isEmpty)
        '- No messages yet'
      else
        ...item.messages
            .take(5)
            .map((message) => '- ${message.sender}: ${message.text}'),
      '',
      'Timeline:',
      if (item.timeline.isEmpty)
        '- No activity yet'
      else
        ...([...item.timeline]..sort((a, b) => b.time.compareTo(a.time)))
            .take(8)
            .map((event) =>
                '- ${_dateLabel(event.time)}: ${event.title} — ${event.detail}'),
    ].join('\n');

    await Clipboard.setData(ClipboardData(text: summary));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Case summary copied')),
      );
    }
  }

  static String _dateLabel(DateTime value) =>
      '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')} ${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
}

class FollowUpControl extends StatelessWidget {
  const FollowUpControl(this.store, this.item, this.onSchedule, this.onClear,
      {super.key});
  final AppStore store;
  final RafCase item;
  final Future<void> Function() onSchedule;
  final Future<void> Function() onClear;

  @override
  Widget build(BuildContext context) {
    final date = store.followUps[item.id];
    final overdue = store.followUpOverdue(item);
    return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color:
                (overdue ? Colors.red : Theme.of(context).colorScheme.primary)
                    .withValues(alpha: .08),
            borderRadius: BorderRadius.circular(16)),
        child: Row(children: [
          Icon(overdue ? Icons.event_busy : Icons.event_outlined,
              color: overdue ? Colors.red : null),
          const SizedBox(width: 10),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(overdue ? 'Follow-up overdue' : 'Next follow-up',
                    style: const TextStyle(fontWeight: FontWeight.w900)),
                Text(date == null
                    ? 'No review date scheduled'
                    : '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}')
              ])),
          if (date != null)
            IconButton(
                tooltip: 'Clear follow-up',
                onPressed: onClear,
                icon: const Icon(Icons.close)),
          TextButton.icon(
              onPressed: onSchedule,
              icon: const Icon(Icons.edit_calendar_outlined),
              label: Text(date == null ? 'Schedule' : 'Change'))
        ]));
  }
}

class SmartCaseInsight extends StatelessWidget {
  const SmartCaseInsight(this.item, {super.key});
  final RafCase item;

  @override
  Widget build(BuildContext context) {
    final color = CaseCard._urgencyColor(item.urgency);
    return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: color.withValues(alpha: .08),
            border: Border.all(color: color.withValues(alpha: .25)),
            borderRadius: BorderRadius.circular(18)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.auto_awesome, color: color),
            const SizedBox(width: 8),
            const Expanded(
                child: Text('Smart RAF insight',
                    style: TextStyle(fontWeight: FontWeight.w900))),
            Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                    color: color.withValues(alpha: .14),
                    borderRadius: BorderRadius.circular(20)),
                child: Text(item.urgency,
                    style: TextStyle(
                        color: color,
                        fontSize: 12,
                        fontWeight: FontWeight.w800)))
          ]),
          const SizedBox(height: 14),
          Text('${item.readiness}% case readiness',
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
          const SizedBox(height: 7),
          LinearProgressIndicator(
              value: item.readiness / 100,
              minHeight: 8,
              color: color,
              borderRadius: BorderRadius.circular(8)),
          const SizedBox(height: 14),
          const Text('Next best action',
              style: TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 3),
          Text(item.nextAction)
        ]));
  }
}

class EvidencePackAssistant extends StatelessWidget {
  const EvidencePackAssistant(this.item, {super.key});
  final RafCase item;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: colors.secondaryContainer.withValues(alpha: .45),
            borderRadius: BorderRadius.circular(16)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.fact_check_outlined),
            const SizedBox(width: 8),
            const Expanded(
                child: Text('Evidence-pack assistant',
                    style: TextStyle(fontWeight: FontWeight.w900))),
            Text('${item.evidencePercent}%',
                style: const TextStyle(fontWeight: FontWeight.w900))
          ]),
          const SizedBox(height: 6),
          const Text(
              'Suggested review based on attached filenames—not legal advice.',
              style: TextStyle(fontSize: 11, color: Colors.grey)),
          const SizedBox(height: 10),
          Wrap(
              spacing: 7,
              runSpacing: 7,
              children: item.evidenceChecklist.entries
                  .map((entry) => Chip(
                      avatar: Icon(
                          entry.value
                              ? Icons.check_circle
                              : Icons.radio_button_unchecked,
                          size: 17,
                          color: entry.value ? Colors.green : Colors.orange),
                      label: Text(entry.key,
                          style: const TextStyle(fontSize: 11))))
                  .toList())
        ]));
  }
}

class TimelineList extends StatelessWidget {
  const TimelineList(this.events, {this.redactDetails = false, super.key});
  final List<TimelineEvent> events;
  final bool redactDetails;

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(top: 8),
        child: Text('No activity yet.', style: TextStyle(color: Colors.grey)),
      );
    }
    final sorted = [...events]..sort((a, b) => b.time.compareTo(a.time));
    return Column(
        children: sorted
            .map((event) => ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading:
                      CircleAvatar(child: Icon(_iconFor(event.icon), size: 18)),
                  title: Text(event.title,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle:
                      Text(redactDetails ? 'Details protected' : event.detail),
                  trailing: Text(_timeLabel(event.time),
                      style: const TextStyle(fontSize: 11, color: Colors.grey)),
                ))
            .toList());
  }

  static IconData _iconFor(String value) => switch (value) {
        'case' => Icons.folder_open,
        'lawyer' => Icons.balance,
        'document' => Icons.description_outlined,
        'message' => Icons.chat_bubble_outline,
        _ => Icons.task_alt,
      };

  static String _timeLabel(DateTime value) {
    final date =
        '${value.day.toString().padLeft(2, '0')}/${value.month.toString().padLeft(2, '0')}';
    final time =
        '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
    return '$date $time';
  }
}

class LawyersPage extends StatelessWidget {
  const LawyersPage(this.store, {super.key});
  final AppStore store;
  @override
  Widget build(BuildContext context) {
    final city = store.profile!.city;
    final sorted = [...store.lawyers]
      ..sort((a, b) => store.match(b, city).compareTo(store.match(a, city)));
    return AppList(key: const ValueKey('lawyers'), children: [
      Heading('Lawyers near $city',
          'Matches explain location, RAF experience and availability.'),
      ...sorted.map((e) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: LawyerCard(store, e, city)))
    ]);
  }
}

class LawyerCard extends StatelessWidget {
  const LawyerCard(this.store, this.lawyer, this.city, {super.key});
  final AppStore store;
  final LawyerInfo lawyer;
  final String city;
  @override
  Widget build(BuildContext context) {
    final score = store.match(lawyer, city);
    final caseload = store.lawyerCaseload(lawyer);
    final load = (caseload / 8).clamp(0.0, 1.0);
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(children: [
              CircleAvatar(
                  radius: 27, child: Text(lawyer.name.substring(0, 1))),
              const SizedBox(width: 14),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(lawyer.name,
                        style: const TextStyle(fontWeight: FontWeight.w900)),
                    Text(
                        '${lawyer.city} · ${lawyer.experience} years RAF experience'),
                    Text(
                        lawyer.available
                            ? 'Accepting referrals'
                            : 'Currently at capacity',
                        style: TextStyle(
                            color: lawyer.available
                                ? Colors.green
                                : Colors.orange)),
                    const SizedBox(height: 6),
                    Row(children: [
                      Expanded(
                          child: LinearProgressIndicator(
                              value: load,
                              borderRadius: BorderRadius.circular(8))),
                      const SizedBox(width: 8),
                      Text('$caseload active',
                          style: const TextStyle(fontSize: 11))
                    ])
                  ])),
              Column(children: [
                Text('$score%',
                    style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        color: Theme.of(context).colorScheme.primary)),
                const Text('MATCH',
                    style: TextStyle(fontSize: 9, letterSpacing: 1.2))
              ]),
              const SizedBox(width: 10),
              FilledButton(
                  onPressed: lawyer.available && store.cases.isNotEmpty
                      ? () => assign(context)
                      : null,
                  child: const Text('Assign'))
            ])));
  }

  void assign(BuildContext context) {
    showDialog(
        context: context,
        builder: (_) => SimpleDialog(
            title: const Text('Assign to case'),
            children: store.cases
                .map((c) => SimpleDialogOption(
                    onPressed: () async {
                      c.lawyer = lawyer.name;
                      c.lawyerId = lawyer.organisationId;
                      c.status = 'Legal review';
                      await store.updateCase(
                          c, '${lawyer.name} assigned to ${c.id}');
                      if (context.mounted) Navigator.pop(context);
                    },
                    child: Text('${c.id} · ${store.patientLabel(c.patient)}')))
                .toList()));
  }
}

class NetworkPage extends StatelessWidget {
  const NetworkPage(this.store, {super.key});
  final AppStore store;
  @override
  Widget build(BuildContext context) =>
      AppList(key: const ValueKey('network'), children: [
        const Heading('Trusted care network',
            'Verified hospitals and legal practices working together.'),
        Wrap(spacing: 12, runSpacing: 12, children: [
          RegisterSummary(Icons.local_hospital, 'Hospitals',
              'Register staff and coordinate referrals.'),
          RegisterSummary(Icons.balance, 'Legal practices',
              'Publish RAF expertise and service areas.')
        ]),
        const SectionTitle('Your organisation'),
        ListTile(
            leading: CircleAvatar(
                child: Icon(store.profile!.role == UserRole.hospital
                    ? Icons.local_hospital
                    : Icons.balance)),
            title: Text(store.profile!.organisation),
            subtitle: Text(
                '${store.profile!.city} · ${store.profile!.verified ? 'Verified' : 'Verification pending'}'),
            trailing: Icon(
                store.profile!.verified
                    ? Icons.verified
                    : Icons.pending_outlined,
                color: store.profile!.verified ? Colors.green : Colors.orange)),
        VerificationStatusCard(store.profile!)
      ]);
}

class VerificationStatusCard extends StatelessWidget {
  const VerificationStatusCard(this.profile, {super.key});
  final Profile profile;

  @override
  Widget build(BuildContext context) {
    final verified = profile.verified;
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(20),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(verified ? Icons.verified : Icons.pending_actions,
                    color: verified ? Colors.green : Colors.orange),
                const SizedBox(width: 10),
                Text(
                    verified ? 'Verified organisation' : 'Verification pending',
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w900))
              ]),
              const SizedBox(height: 8),
              Text(
                  verified
                      ? 'This organisation is approved as part of the trusted Health Connect RAF network.'
                      : 'An administrator can approve this organisation in Supabase by opening the organisations table and setting verified to true.',
                  style: const TextStyle(color: Colors.grey)),
              if (!verified) ...[
                const SizedBox(height: 12),
                const ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.badge_outlined),
                    title: Text('Confirm organisation identity')),
                const ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.location_on_outlined),
                    title: Text('Confirm service location')),
                const ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.security_outlined),
                    title: Text('Approve trusted RAF case access')),
              ]
            ])));
  }
}

class RegisterSummary extends StatelessWidget {
  const RegisterSummary(this.icon, this.title, this.text, {super.key});
  final IconData icon;
  final String title, text;
  @override
  Widget build(BuildContext context) => SizedBox(
      width: 330,
      child: Card(
          child: Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(child: Icon(icon)),
                    const SizedBox(height: 14),
                    Text(title,
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w900)),
                    Text(text, style: const TextStyle(color: Colors.grey))
                  ]))));
}

class MessagesPage extends StatelessWidget {
  const MessagesPage(this.store, {super.key});
  final AppStore store;
  @override
  Widget build(BuildContext context) =>
      AppList(key: const ValueKey('messages'), children: [
        const Heading('Case messages',
            'Keep hospital and legal conversations attached to the RAF matter.'),
        if (store.cases.isEmpty)
          const EmptyState(Icons.chat_bubble_outline, 'No conversations',
              'Create a case to start a secure conversation.')
        else
          ...store.cases.map((c) => ListTile(
              leading:
                  const CircleAvatar(child: Icon(Icons.chat_bubble_outline)),
              title: Text('${c.id} · ${store.patientLabel(c.patient)}'),
              subtitle: Text(c.messages.isEmpty
                  ? 'No messages yet'
                  : c.messages.last.text),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showDialog(
                  context: context, builder: (_) => ChatDialog(store, c))))
      ]);
}

class ChatDialog extends StatefulWidget {
  const ChatDialog(this.store, this.item, {super.key});
  final AppStore store;
  final RafCase item;
  @override
  State<ChatDialog> createState() => _ChatDialogState();
}

class _ChatDialogState extends State<ChatDialog> {
  final text = TextEditingController();
  @override
  Widget build(BuildContext context) => AlertDialog(
          title: Text(widget.item.id),
          content: SizedBox(
              width: 520,
              height: 400,
              child: Column(children: [
                Expanded(
                    child: ListView(
                        children: widget.item.messages
                            .map((m) => ListTile(
                                title: Text(m.sender),
                                subtitle: Text(m.text),
                                trailing: Text(
                                    '${m.time.hour.toString().padLeft(2, '0')}:${m.time.minute.toString().padLeft(2, '0')}')))
                            .toList())),
                Row(children: [
                  Expanded(
                      child: TextField(
                          controller: text,
                          decoration: const InputDecoration(
                              hintText: 'Write a case message'))),
                  IconButton(onPressed: send, icon: const Icon(Icons.send))
                ])
              ])),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'))
          ]);
  Future<void> send() async {
    if (text.text.trim().isEmpty) return;
    final message = ChatMessage(
        widget.store.profile!.name, text.text.trim(), DateTime.now());
    setState(() => widget.item.messages.add(message));
    if (BackendConfig.enabled) {
      await SupabaseService.sendMessage(
          caseId: widget.item.id, body: message.text);
    }
    text.clear();
    await widget.store
        .updateCase(widget.item, 'New message on ${widget.item.id}');
  }
}

class NewCaseDialog extends StatefulWidget {
  const NewCaseDialog(this.store, {super.key});
  final AppStore store;
  @override
  State<NewCaseDialog> createState() => _NewCaseDialogState();
}

class _NewCaseDialogState extends State<NewCaseDialog> {
  final patient = TextEditingController(), city = TextEditingController();
  final form = GlobalKey<FormState>();
  bool recommend = true;
  @override
  void initState() {
    super.initState();
    city.text = widget.store.profile!.city;
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: const Text('Create RAF case'),
          content: SizedBox(
              width: 480,
              child: Form(
                  key: form,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextFormField(
                        controller: patient,
                        decoration: const InputDecoration(
                            labelText: 'Patient full name'),
                        validator: (v) =>
                            (v ?? '').trim().isEmpty ? 'Required' : null),
                    const SizedBox(height: 12),
                    TextFormField(
                        controller: city,
                        decoration: const InputDecoration(
                            labelText: 'Accident city / location'),
                        validator: (v) =>
                            (v ?? '').trim().isEmpty ? 'Required' : null),
                    SwitchListTile(
                        value: recommend,
                        onChanged: (v) => setState(() => recommend = v),
                        title: const Text('Recommend nearby RAF lawyers'))
                  ]))),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: create, child: const Text('Create secure case'))
          ]);
  Future<void> create() async {
    if (!form.currentState!.validate()) return;
    final id =
        'HC-RAF-${DateTime.now().millisecondsSinceEpoch.toString().substring(7)}';
    final item = RafCase(
        id: id,
        patient: patient.text.trim(),
        hospital: widget.store.profile!.organisation,
        city: city.text.trim(),
        status: recommend ? 'Lawyer matching' : 'New referral',
        created: DateTime.now());
    await widget.store.addCase(item);
    if (mounted) Navigator.pop(context);
  }
}

class Notices extends StatelessWidget {
  const Notices(this.store, {super.key});
  final AppStore store;
  @override
  Widget build(BuildContext context) => SafeArea(
      child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Notifications',
                    style:
                        TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
                const SizedBox(height: 10),
                if (store.notices.isEmpty)
                  const Text('You are all caught up.')
                else
                  ...store.notices.take(8).map((e) => ListTile(
                      leading: const Icon(Icons.notifications_none),
                      title: Text(e)))
              ])));
}

class AppList extends StatelessWidget {
  const AppList({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => ListView(
      padding: const EdgeInsets.fromLTRB(22, 12, 22, 100), children: children);
}

class Heading extends StatelessWidget {
  const Heading(this.title, this.subtitle, {super.key});
  final String title, subtitle;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title,
            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900)),
        Text(subtitle, style: const TextStyle(color: Colors.grey))
      ]));
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key});
  final String title;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 10),
      child: Text(title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)));
}

class EmptyState extends StatelessWidget {
  const EmptyState(this.icon, this.title, this.text, {super.key});
  final IconData icon;
  final String title, text;
  @override
  Widget build(BuildContext context) => Card(
      child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(children: [
            Icon(icon, size: 42, color: Colors.grey),
            const SizedBox(height: 10),
            Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
            Text(text,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.grey))
          ])));
}

class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 56, this.translucent = false});
  final double size;
  final bool translucent;
  @override
  Widget build(BuildContext context) => SizedBox.square(
      dimension: size,
      child: DecoratedBox(
          decoration: BoxDecoration(
              color: translucent
                  ? Colors.white.withValues(alpha: .16)
                  : const Color(0xFF0A376A),
              borderRadius: BorderRadius.circular(size * .27)),
          child: Stack(alignment: Alignment.center, children: [
            Container(
                width: size * .68,
                height: size * .23,
                decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(size))),
            Container(
                width: size * .23,
                height: size * .68,
                decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(size))),
            Icon(Icons.favorite_rounded,
                size: size * .42, color: const Color(0xFFFF5C55))
          ])));
}
