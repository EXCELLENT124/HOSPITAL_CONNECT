import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseService {
  SupabaseService._();

  static SupabaseClient get client => Supabase.instance.client;

  static Future<void> signIn({
    required String email,
    required String password,
  }) async {
    await client.auth.signInWithPassword(email: email, password: password);
  }

  static Future<String> register({
    required String name,
    required String email,
    required String password,
    required String role,
    required String organisation,
    required String city,
  }) async {
    final isPatient = role == 'patient';
    final response = await client.auth.signUp(
      email: email,
      password: password,
      data: {
        'name': name,
        'account_type': role,
        if (!isPatient) 'organisation': organisation,
        'city': city,
      },
    );
    final user = response.user;
    if (user == null) {
      throw const AuthException('Registration did not create a user.');
    }

    return user.id;
  }

  static Future<void> signOut() => client.auth.signOut();

  static Future<Map<String, dynamic>?> currentOrganisation() async {
    final user = client.auth.currentUser;
    if (user == null) return null;

    final membership = await client
        .from('memberships')
        .select('organisation_id')
        .eq('user_id', user.id)
        .limit(1)
        .maybeSingle();
    if (membership == null) {
      final type = user.userMetadata?['account_type'] as String?;
      if (type == 'patient') {
        return {
          'id': null,
          'name': 'Patient account',
          'type': 'patient',
          'city': user.userMetadata?['city'] ?? 'Johannesburg',
          'verified': true,
          'suspended': false,
          'email': user.email,
          'display_name': user.userMetadata?['name'],
          'is_platform_admin': false,
        };
      }
      return null;
    }

    final organisation = await client
        .from('organisations')
        .select('id, name, type, city, verified, suspended')
        .eq('id', membership['organisation_id'])
        .maybeSingle();
    if (organisation == null) return null;
    if (organisation['suspended'] == true) {
      await client.auth.signOut();
      throw const AuthException('This organisation has been suspended.');
    }

    var account = <String, dynamic>{};
    try {
      account = await client
              .from('user_profiles')
              .select('suspended, is_platform_admin')
              .eq('user_id', user.id)
              .maybeSingle() ??
          {};
    } on PostgrestException {
      // Advanced migration has not been applied yet.
    }
    if (account['suspended'] == true) {
      await client.auth.signOut();
      throw const AuthException('This account has been suspended.');
    }

    return {
      ...organisation,
      'email': user.email,
      'display_name': user.userMetadata?['name'],
      'is_platform_admin': account['is_platform_admin'] ?? false,
    };
  }

  static Future<List<Map<String, dynamic>>> fetchOrganisationMembers() async {
    final organisation = await currentOrganisation();
    if (organisation == null) return [];
    final memberships = await client
        .from('memberships')
        .select('user_id, member_role')
        .eq('organisation_id', organisation['id']);
    final ids = memberships.map((row) => row['user_id'] as String).toList();
    if (ids.isEmpty) return [];
    final profiles = await client
        .from('user_profiles')
        .select('user_id, display_name, email, suspended')
        .inFilter('user_id', ids);
    return profiles.cast<Map<String, dynamic>>();
  }

  static Future<List<Map<String, dynamic>>> fetchLawyers() async {
    final rows = await client
        .from('organisations')
        .select('id, name, city')
        .eq('type', 'lawyer')
        .eq('verified', true)
        .eq('suspended', false)
        .order('name');
    return rows.cast<Map<String, dynamic>>();
  }

  static Future<List<Map<String, dynamic>>> fetchCases() async {
    final caseRows = await client.from('raf_cases').select('''
          id,
          patient_name,
          accident_city,
          status,
          assigned_lawyer_id,
          assigned_lawyer_name,
          patient_email,
          patient_phone,
          patient_id_number,
          patient_date_of_birth,
          patient_address,
          emergency_contact_name,
          emergency_contact_phone,
          accident_date,
          accident_description,
          patient_user_id,
          created_at,
          hospital:organisations!raf_cases_hospital_id_fkey(name)
        ''').order('created_at', ascending: false);

    final documentRows = await client
        .from('case_documents')
        .select('case_id, file_name')
        .order('created_at', ascending: true);
    final messageRows = await client
        .from('case_messages')
        .select('case_id, body, created_at')
        .order('created_at', ascending: true);

    final documentsByCase = <String, List<String>>{};
    for (final row in documentRows) {
      final caseId = row['case_id'] as String;
      documentsByCase.putIfAbsent(caseId, () => []).add(row['file_name']);
    }

    final messagesByCase = <String, List<Map<String, dynamic>>>{};
    for (final row in messageRows) {
      final caseId = row['case_id'] as String;
      messagesByCase.putIfAbsent(caseId, () => []).add(row);
    }

    return caseRows
        .map<Map<String, dynamic>>((row) => {
              ...row,
              'documents': documentsByCase[row['id']] ?? <String>[],
              'messages': messagesByCase[row['id']] ?? <Map<String, dynamic>>[],
            })
        .toList();
  }

  static Future<void> saveCase({
    required String id,
    required String patientName,
    required String city,
    required String status,
    String? lawyerName,
    String? lawyerId,
    String? patientEmail,
    String? patientPhone,
    String? patientIdNumber,
    DateTime? patientDateOfBirth,
    String? patientAddress,
    String? emergencyContactName,
    String? emergencyContactPhone,
    DateTime? accidentDate,
    String? accidentDescription,
  }) async {
    final user = client.auth.currentUser;
    if (user == null) return;
    final membership = await client
        .from('memberships')
        .select('organisation_id')
        .eq('user_id', user.id)
        .limit(1)
        .maybeSingle();
    if (membership == null) return;

    final existing =
        await client.from('raf_cases').select('id').eq('id', id).maybeSingle();

    if (existing != null) {
      await client.from('raf_cases').update({
        'patient_name': patientName,
        'accident_city': city,
        'status': status,
        'assigned_lawyer_id': lawyerId,
        'assigned_lawyer_name': lawyerName,
        'patient_email': patientEmail,
        'patient_phone': patientPhone,
        'patient_id_number': patientIdNumber,
        'patient_date_of_birth': patientDateOfBirth?.toIso8601String(),
        'patient_address': patientAddress,
        'emergency_contact_name': emergencyContactName,
        'emergency_contact_phone': emergencyContactPhone,
        'accident_date': accidentDate?.toIso8601String(),
        'accident_description': accidentDescription,
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('id', id);
      return;
    }

    await client.from('raf_cases').insert({
      'id': id,
      'patient_name': patientName,
      'hospital_id': membership['organisation_id'],
      'accident_city': city,
      'status': status,
      'assigned_lawyer_id': lawyerId,
      'assigned_lawyer_name': lawyerName,
      'patient_email': patientEmail,
      'patient_phone': patientPhone,
      'patient_id_number': patientIdNumber,
      'patient_date_of_birth': patientDateOfBirth?.toIso8601String(),
      'patient_address': patientAddress,
      'emergency_contact_name': emergencyContactName,
      'emergency_contact_phone': emergencyContactPhone,
      'accident_date': accidentDate?.toIso8601String(),
      'accident_description': accidentDescription,
      'created_by': user.id,
    });
  }

  static Future<void> sendMessage({
    required String caseId,
    required String body,
  }) async {
    final user = client.auth.currentUser;
    if (user == null) return;
    await client.from('case_messages').insert({
      'case_id': caseId,
      'sender_id': user.id,
      'body': body,
    });
    await client.rpc('notify_case_participants', params: {
      'target_case': caseId,
      'notification_type': 'message',
      'notification_title': 'New case message',
      'notification_body': body,
    });
  }

  static Future<void> notifyCase({
    required String caseId,
    required String type,
    required String title,
    required String body,
  }) async {
    await client.rpc('notify_case_participants', params: {
      'target_case': caseId,
      'notification_type': type,
      'notification_title': title,
      'notification_body': body,
    });
  }

  static Future<void> uploadDocument({
    required String caseId,
    required String fileName,
    required List<int> bytes,
    String category = 'Other',
  }) async {
    final user = client.auth.currentUser;
    if (user == null) {
      throw const AuthException('Sign in before uploading.');
    }
    final path = '$caseId/${DateTime.now().millisecondsSinceEpoch}_$fileName';
    await client.storage.from('case-documents').uploadBinary(
          path,
          Uint8List.fromList(bytes),
          fileOptions: const FileOptions(upsert: false),
        );
    final document = await client
        .from('case_documents')
        .insert({
          'case_id': caseId,
          'uploaded_by': user.id,
          'uploader_name': user.userMetadata?['name'] ?? user.email,
          'file_name': fileName,
          'storage_path': path,
          'category': category,
        })
        .select('id')
        .single();
    await client.from('document_history').insert({
      'document_id': document['id'],
      'case_id': caseId,
      'actor_id': user.id,
      'action': 'uploaded',
      'detail': '$fileName · $category',
    });
    await client.rpc('notify_case_participants', params: {
      'target_case': caseId,
      'notification_type': 'document',
      'notification_title': 'New case document',
      'notification_body': fileName,
    });
  }

  static Future<void> uploadProfessionalDocument({
    required String fileName,
    required List<int> bytes,
    String category = 'Professional approval',
  }) async {
    final user = client.auth.currentUser;
    if (user == null) {
      throw const AuthException('Sign in before uploading approval documents.');
    }
    final organisation = await currentOrganisation();
    if (organisation == null) {
      throw const AuthException('Organisation profile was not found.');
    }
    final organisationId = organisation['id'] as String;
    final path =
        '$organisationId/${DateTime.now().millisecondsSinceEpoch}_$fileName';
    await client.storage.from('professional-documents').uploadBinary(
          path,
          Uint8List.fromList(bytes),
          fileOptions: const FileOptions(upsert: false),
        );
    await client.from('professional_documents').insert({
      'organisation_id': organisationId,
      'uploaded_by': user.id,
      'uploader_name': user.userMetadata?['name'] ?? user.email,
      'file_name': fileName,
      'storage_path': path,
      'category': category,
    });
  }

  static Future<void> replaceDocument({
    required Map<String, dynamic> previous,
    required String fileName,
    required List<int> bytes,
  }) async {
    final user = client.auth.currentUser!;
    final caseId = previous['case_id'] as String;
    final path = '$caseId/${DateTime.now().millisecondsSinceEpoch}_$fileName';
    await client.storage.from('case-documents').uploadBinary(
          path,
          Uint8List.fromList(bytes),
          fileOptions: const FileOptions(upsert: false),
        );
    final replacement = await client
        .from('case_documents')
        .insert({
          'case_id': caseId,
          'uploaded_by': user.id,
          'uploader_name': user.userMetadata?['name'] ?? user.email,
          'file_name': fileName,
          'storage_path': path,
          'category': previous['category'] ?? 'Other',
          'version': ((previous['version'] as num?)?.toInt() ?? 1) + 1,
          'replaced_document_id': previous['id'],
        })
        .select('id')
        .single();
    await client
        .from('case_documents')
        .update({'is_current': false}).eq('id', previous['id']);
    await client.from('document_history').insert({
      'document_id': replacement['id'],
      'case_id': caseId,
      'actor_id': user.id,
      'action': 'replaced',
      'detail': '${previous['file_name']} → $fileName',
    });
  }

  static Future<List<Map<String, dynamic>>> fetchTasks(String caseId) async {
    final rows = await client
        .from('case_tasks')
        .select()
        .eq('case_id', caseId)
        .order('created_at', ascending: false);
    final result = rows.cast<Map<String, dynamic>>();
    for (final task in result) {
      final comments = await client
          .from('task_comments')
          .select('id, body, author_id, created_at')
          .eq('task_id', task['id'])
          .order('created_at');
      task['comments'] = comments;
    }
    return result;
  }

  static Future<void> createTask({
    required String caseId,
    required String title,
    required String priority,
    required DateTime dueAt,
    String? assignedTo,
    String description = '',
  }) async {
    final user = client.auth.currentUser!;
    await client.from('case_tasks').insert({
      'case_id': caseId,
      'title': title,
      'description': description,
      'assigned_to': assignedTo,
      'created_by': user.id,
      'priority': priority,
      'due_at': dueAt.toIso8601String(),
    });
    await client.rpc('notify_case_participants', params: {
      'target_case': caseId,
      'notification_type': 'task',
      'notification_title': 'New case task',
      'notification_body': title,
    });
  }

  static Future<void> setTaskComplete(String taskId, bool complete) async {
    await client.from('case_tasks').update({
      'completed_at': complete ? DateTime.now().toIso8601String() : null,
      'updated_at': DateTime.now().toIso8601String(),
    }).eq('id', taskId);
  }

  static Future<void> addTaskComment(String taskId, String body) async {
    await client.from('task_comments').insert({
      'task_id': taskId,
      'author_id': client.auth.currentUser!.id,
      'body': body,
    });
  }

  static Future<List<Map<String, dynamic>>> fetchDocuments(
      String caseId) async {
    final rows = await client
        .from('case_documents')
        .select()
        .eq('case_id', caseId)
        .eq('is_current', true)
        .order('created_at', ascending: false);
    return rows.cast<Map<String, dynamic>>();
  }

  static Future<String> documentUrl(String storagePath) =>
      client.storage.from('case-documents').createSignedUrl(storagePath, 900);

  static Future<String> professionalDocumentUrl(String storagePath) =>
      client.storage
          .from('professional-documents')
          .createSignedUrl(storagePath, 900);

  static Future<void> updateDocument({
    required String id,
    required String caseId,
    required String fileName,
    required String category,
  }) async {
    await client.from('case_documents').update({
      'file_name': fileName,
      'category': category,
      'updated_at': DateTime.now().toIso8601String(),
    }).eq('id', id);
    await client.from('document_history').insert({
      'document_id': id,
      'case_id': caseId,
      'actor_id': client.auth.currentUser!.id,
      'action': 'renamed',
      'detail': '$fileName · $category',
    });
  }

  static Future<List<Map<String, dynamic>>> fetchDocumentHistory(
      String caseId) async {
    final rows = await client
        .from('document_history')
        .select()
        .eq('case_id', caseId)
        .order('created_at', ascending: false);
    return rows.cast<Map<String, dynamic>>();
  }

  static Future<List<Map<String, dynamic>>> fetchNotifications() async {
    final rows = await client
        .from('notifications')
        .select()
        .order('created_at', ascending: false)
        .limit(100);
    return rows.cast<Map<String, dynamic>>();
  }

  static Future<void> markNotificationRead(String id) async {
    await client
        .from('notifications')
        .update({'read_at': DateTime.now().toIso8601String()}).eq('id', id);
  }

  static Future<Map<String, dynamic>> fetchAdminDashboard() async {
    final organisations = await client
        .from('organisations')
        .select('id, name, type, city, verified, suspended, created_at')
        .order('created_at', ascending: false);
    final users = await client
        .from('user_profiles')
        .select('user_id, display_name, email, suspended, created_at')
        .order('created_at', ascending: false);
    final audits = await client
        .from('audit_logs')
        .select()
        .order('created_at', ascending: false)
        .limit(50);
    final professionalDocuments = await client
        .from('professional_documents')
        .select()
        .order('created_at', ascending: false);
    return {
      'organisations': organisations,
      'users': users,
      'audits': audits,
      'professionalDocuments': professionalDocuments
    };
  }

  static Future<void> setOrganisationState(
      String id, bool verified, bool suspended) async {
    await client.rpc('set_organisation_state', params: {
      'target_id': id,
      'approve': verified,
      'suspend': suspended,
    });
  }

  static Future<void> setUserSuspended(String id, bool suspended) async {
    await client.rpc('set_user_suspended',
        params: {'target_id': id, 'suspend': suspended});
  }
}
