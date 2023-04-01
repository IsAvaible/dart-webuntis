import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:huntis/main.dart';
import 'package:intl/intl.dart';
import 'package:string_similarity/string_similarity.dart';

/// https://github.com/IsAvaible/dart-webuntis
/// Asynchronous Dart wrapper for the WebUntis API.
/// Initialize a new object by calling the [.init] method.
///
/// Almost all methods require the response to be awaited.
/// Make sure to watch the following video to learn about proper Integration
/// of asynchronous code into your flutter application:
/// https://www.youtube.com/watch?v=OTS-ap9_aXc
///
/// Add this to your project dependencies:
/// ```yaml
/// http: ^0.13.4
/// string_similarity: ^2.0.0
///  ```

class Session {
  String? _sessionId;
  IdProvider? userId, userKlasseId;

  final String server, school, username, _password, userAgent;

  int _requestId = 0;
  late final IOClient _http;

  final LinkedHashMap<String, _CacheEntry> _cache = LinkedHashMap();
  int cacheLengthMaximum = 20;
  int cacheDisposeTime = 30;

  Session._internal(
      this.server, this.school, this.username, this._password, this.userAgent) {
    final ioc = HttpClient();
    ioc.badCertificateCallback =
        (X509Certificate cert, String host, int port) => true;
    _http = IOClient(ioc);
  }

  static Future<Session> init(
      String server, String school, String username, String password,
      {String userAgent = "Dart Untis API"}) async {
    Session session =
    Session._internal(server, school, username, password, userAgent);
    await session.login();
    return session;
  }

  static Session initNoLogin(
      String server, String school, String username, String password,
      {String userAgent = "Dart Untis API"}) {
    Session session =
    Session._internal(server, school, username, password, userAgent);
    return session;
  }

  Future<dynamic> _request(Map<String, Object> requestBody,
      {bool useCache = false}) async {
    var url = Uri.parse("https://$server/WebUntis/jsonrpc.do?school=$school");
    http.Response response;
    String requestBodyAsString = jsonEncode(requestBody);

    if (useCache && _cache.keys.contains(requestBodyAsString)) {
      if (_cache[requestBodyAsString]!
          .creationTime
          .difference(DateTime.now())
          .inMinutes >
          cacheDisposeTime) {
        _cache.remove(requestBodyAsString);
        return await _request(requestBody, useCache: useCache);
      }
      response = _cache[requestBodyAsString]!.value;
    } else {
      response = await _http.post(
        url,
        body: requestBodyAsString,
        headers: {"Cookie": "JSESSIONID=$_sessionId"},
      );
    }

    _cache[requestBodyAsString] = _CacheEntry(DateTime.now(), response);
    if (_cache.length > cacheLengthMaximum) {
      _cache.remove(_cache.keys.take(1).toList()[0].toString());
    }

    LinkedHashMap<String, dynamic> responseBody = jsonDecode(response.body);

    if (response.statusCode != 200 || responseBody.containsKey("error")) {
      throw HttpException(
        "An exception occurred while communicating with the WebUntis API: "
            "${responseBody["error"]}"
            "${(responseBody["error"]["code"] == -8520) ? "\nYou need to authenticate with .login() first." : ""}",
      );
    } else {
      var result = responseBody["result"];
      return result;
    }
  }

  Map<String, Object> _postify(String method, Map<String, Object> parameters) {
    var postBody = {
      "id": "req-${_requestId += 1}",
      "method": method,
      "params": parameters,
      "jsonrpc": "2.0",
    };
    return postBody;
  }

  Future<void> login() async {
    var result = await _request(_postify("authenticate",
        {"user": username, "password": _password, "client": userAgent}));
    _sessionId = result["sessionId"] as String;
    if (result.containsKey("personId")) {
      userId = IdProvider._(
        result["personType"] as int,
        result["personId"] as int,
      );
    }
    if (result.containsKey("klasseId")) {
      userKlasseId = IdProvider._withType(
        IdProviderTypes.klasse,
        result["klasseId"] as int,
      );
    }
  }

  bool _isSamePeriod(Period period1, Period period2) {
    bool isSame =
        period1.endTime == period2.startTime && period1.name == period2.name;
    if (isSame &&
        period1.teacherIds.isNotEmpty &&
        period2.teacherIds.isNotEmpty) {
      isSame = period1.teacherIds[0].id == period2.teacherIds[0].id &&
          period1.isCancelled == period2.isCancelled;
    } else {
      isSame = false;
    }
    return isSame;
  }

  Future<List<Period>> getTimetable(
      IdProvider idProvider, {
        DateTime? startDate,
        DateTime? endDate,
        bool useCache = false,
        bool combineSamePeriods = true,
      }) async {
    var id = idProvider.id, type = idProvider.type.index + 1;

    startDate = startDate ?? DateTime.now();
    endDate = endDate ?? startDate;
    if (startDate.compareTo(endDate) == 1) {
      throw Exception("startDate must be equal to or before the endDate.");
    }
    conv(DateTime dateTime) =>
        dateTime.toIso8601String().substring(0, 10).replaceAll("-", "");

    var rawTimetable = await _request(
      _postify(
        "getTimetable",
        {
          "id": id,
          "type": type,
          "startDate": conv.call(startDate),
          "endDate": conv.call(endDate),
        },
      ),
      useCache: useCache,
    );

    List<Period> timetable = _parseTimetable(rawTimetable);

    // Search for all corresponding names
    List<Subject> allSubjects = await getSubjects();
    for (Period period in timetable) {
      if (period.subjectIds.isNotEmpty) {
        int id = period.subjectIds[0].id;
        period.name =
            allSubjects.where((element) => element.id.id == id).first.name;
      }
    }
    // Search for all corresponding teacher names
    List<Teacher> allTeachers = await getTeachers();
    for (Period period in timetable) {
      if (period.teacherIds.isNotEmpty) {
        int id = period.teacherIds[0].id;
        Iterable<Teacher> possibleTeachers =
        allTeachers.where((element) => element.id.id == id);
        if (possibleTeachers.isNotEmpty) {
          period.teacherName = possibleTeachers.first.surName!;
          if (possibleTeachers.first.id.id == 80) {
            period.isCancelled = true; // Cancelled Period (EVA) for my school
          }
        }
      }
    }
    // Search for corresponding room number
    List<Room> allRooms = await getRooms();
    for (Period period in timetable) {
      if (period.roomIds.isNotEmpty) {
        int id = period.roomIds[0].id;
        Iterable<Room> possibleRooms =
        allRooms.where((element) => element.id.id == id);
        if (possibleRooms.isNotEmpty) {
          period.roomName = possibleRooms.first.name!;
        }
      }
    }

    // Sort by time
    timetable.sort((a, b) {
      int sorter = a.startTime.compareTo(b.startTime);
      if (sorter == 0) {
        sorter = a.name.compareTo(b.name);
      }
      return sorter;
    });
    if (combineSamePeriods) {
      for (int i = 0; i < timetable.length; i++) {
        for (int j = 0; j < timetable.length; j++) {
          if (_isSamePeriod(timetable[i], timetable[j])) {
            if (timetable[i].startTime.compareTo(timetable[j].startTime) < 0) {
              timetable[i].endTime = timetable[j].endTime;
            } else {
              timetable[i].startTime = timetable[j].startTime;
            }
            timetable.remove(timetable[j]);
          }
        }
      }
    }

    return timetable;
  }

  List<Period> _parseTimetable(List<dynamic> rawTimetable) {
    return List.generate(rawTimetable.length, (index) {
      var period = Map.fromIterable([
        "id",
        "date",
        "startTime",
        "endTime",
        "kl",
        "te",
        "su",
        "ro",
        "activityType",
        "code",
        "lstype",
        "lstext",
        "statflags",
      ],
          value: (key) => rawTimetable[index].containsKey(key)
              ? rawTimetable[index][key]
              : null);
      return Period._(
        period["id"] as int,
        'NoName',
        'NoTeacher',
        'NoRoom',
        DateTime.parse(
            "${period["date"]} ${period["startTime"].toString().padLeft(4, "0")}"),
        DateTime.parse(
            "${period["date"]} ${period["endTime"].toString().padLeft(4, "0")}"),
        List.generate(
            period["kl"].length,
                (index) => IdProvider._withType(
                IdProviderTypes.klasse, period["kl"][index]["id"])),
        List.generate(
            period["te"].length,
                (index) => IdProvider._withType(
                IdProviderTypes.klasse, period["te"][index]["id"])),
        List.generate(
            period["su"].length,
                (index) => IdProvider._withType(
                IdProviderTypes.klasse, period["su"][index]["id"])),
        List.generate(
            period["ro"].length,
                (index) => IdProvider._withType(
                IdProviderTypes.klasse, period["ro"][index]["id"])),
        period["activityType"],
        (period["code"] ?? "") == "cancelled",
        period["code"],
        period["lstype"] ?? "ls",
        period["lstext"],
        period["statflags"],
      );
    });
  }

  Future<List<Subject>> getSubjects({bool useCache = false}) async {
    List<dynamic> rawSubjects =
    await _request(_postify("getSubjects", {}), useCache: useCache);
    return _parseSubjects(rawSubjects);
  }

  List<Subject> _parseSubjects(List<dynamic> rawSubjects) {
    return List.generate(rawSubjects.length, (index) {
      var subject = rawSubjects[index];
      return Subject._(
        IdProvider._withType(IdProviderTypes.subject, subject["id"]),
        subject["name"],
        subject["longName"],
      );
    });
  }

  Future<Timegrid> getTimegrid({bool useCache = true}) async {
    List<dynamic> rawTimegrid =
    await _request(_postify("getTimegridUnits", {}), useCache: useCache);
    return _parseTimegrid(rawTimegrid);
  }

  Timegrid _parseTimegrid(List<dynamic> rawTimegrid) {
    return Timegrid._fromList(
      List.generate(
        7,
            (day) {
          if (rawTimegrid.map((e) => e["day"]).contains(day)) {
            var dayDict =
            rawTimegrid.firstWhere((element) => (element["day"] == day));
            List<dynamic> dayData = dayDict["timeUnits"];

            List.generate(
              dayData.length,
                  (timePeriod) => List.generate(
                2,
                    (periodBorder) {
                  String border =
                  List.from(["startTime", "endTime"])[periodBorder];
                  String time =
                  dayData[timePeriod][border].toString().padLeft(4, "0");
                  String hour = time.substring(0, 2),
                      minute = time.substring(2, 4);
                  return DayTime(int.parse(hour), int.parse(minute));
                },
              ),
            );
          } else {
            return null;
          }
          return null;
        },
      ),
    );
  }

  Future<Schoolyear> getCurrentSchoolyear({bool useCache = true}) async {
    Map<String, dynamic> rawSchoolyear =
    await _request(_postify("getCurrentSchoolyear", {}));
    return _parseSchoolyear(rawSchoolyear);
  }

  Future<List<Schoolyear>> getSchoolyears({bool useCache = true}) async {
    List<dynamic> rawSchoolyears =
    await _request(_postify("getSchoolyears", {}));
    return List.generate(rawSchoolyears.length,
            (year) => _parseSchoolyear(rawSchoolyears[year]));
  }

  Schoolyear _parseSchoolyear(Map rawSchoolyear) {
    return Schoolyear._(
        rawSchoolyear["id"],
        rawSchoolyear["name"],
        DateTime.parse(rawSchoolyear["startDate"].toString()),
        DateTime.parse(rawSchoolyear["endDate"].toString()));
  }

  Future<List<Student>> getStudents({bool useCache = true}) async {
    List<dynamic> rawStudents =
    await _request(_postify("getStudents", {}), useCache: useCache);
    return _parseStudents(rawStudents);
  }

  List<Student> _parseStudents(List<dynamic> rawStudents) {
    return List.generate(rawStudents.length, (index) {
      var student = rawStudents[index];
      return Student._(
        IdProvider._withType(IdProviderTypes.student, student["id"]),
        student.containsKey("key") ? student["key"] : null,
        student.containsKey("name") ? student["name"] : null,
        student.containsKey("foreName") ? student["foreName"] : null,
        student.containsKey("longName") ? student["longName"] : null,
        student.containsKey("gender") ? student["gender"] : null,
      );
    });
  }

  Future<List<Teacher>> getTeachers({bool useCache = false}) async {
    List<dynamic> rawTeachers = await customRequest("getTeachers", {});
    return _parseTeachers(rawTeachers);
  }

  List<Teacher> _parseTeachers(List<dynamic> rawTeachers) {
    return List.generate(rawTeachers.length, (index) {
      var teacher = rawTeachers[index];
      return Teacher._(
        IdProvider._withType(IdProviderTypes.teacher, teacher["id"]),
        teacher.containsKey("key") ? teacher["key"] : null,
        teacher.containsKey("name") ? teacher["name"] : null,
        teacher.containsKey("foreName") ? teacher["foreName"] : null,
        teacher.containsKey("longName") ? teacher["longName"] : null,
        teacher.containsKey("title") ? teacher["title"] : null,
        teacher.containsKey("active") ? teacher["active"] : null,
      );
    });
  }

  Future<List<Room>> getRooms({bool useCache = true}) async {
    List<dynamic> rawRooms =
    await _request(_postify("getRooms", {}), useCache: useCache);
    return _parseRooms(rawRooms);
  }

  List<Room> _parseRooms(List<dynamic> rawRooms) {
    return List.generate(rawRooms.length, (index) {
      var room = rawRooms[index];
      return Room._(
        IdProvider._withType(IdProviderTypes.room, room["id"]),
        room.containsKey("name") ? room["name"] : null,
        room.containsKey("longName") ? room["longName"] : null,
        room.containsKey("foreColor") ? room["foreColor"] : null,
        room.containsKey("backColor") ? room["backColor"] : null,
      );
    });
  }

  Future<List<Klasse>> getKlassen(int schoolyearId,
      {bool useCache = true}) async {
    List<dynamic> rawKlassen = await _request(
        _postify("getKlassen", {"schoolyearId": schoolyearId}),
        useCache: useCache);
    return _parseKlassen(rawKlassen, schoolyearId);
  }

  List<Klasse> _parseKlassen(List<dynamic> rawKlassen, int schoolyearId) {
    return List.generate(rawKlassen.length, (index) {
      Map klasse = rawKlassen[index];
      var teachers = klasse.keys.where((e) => e.startsWith("teacher")).toList();
      return Klasse._(
          IdProvider._withType(IdProviderTypes.klasse, klasse["id"]),
          schoolyearId,
          klasse.containsKey("name") ? klasse["name"] : null,
          klasse.containsKey("longName") ? klasse["longName"] : null,
          klasse.containsKey("foreColor") ? klasse["foreColor"] : null,
          klasse.containsKey("backColor") ? klasse["backColor"] : null,
          List.generate(
              teachers.length,
                  (i) => IdProvider._withType(
                  IdProviderTypes.teacher, klasse[teachers[i]])));
    });
  }

  Future<IdProvider?> searchPerson(
      String forename, String surname, bool isTeacher,
      {String birthdata = "0"}) async {
    int response = await _request(
      _postify(
        "getPersonId",
        {
          "type": isTeacher ? 2 : 5,
          "sn": surname,
          "fn": forename,
          "dob": birthdata
        },
      ),
    );
    return response == 0 ? null : IdProvider._(isTeacher ? 2 : 5, response);
  }

  Future<SearchMatches?> searchStudent(
      [String? forename,
        String? surname,
        int maxMatchCount = 5,
        double minMatchRating = 0.4]) async {
    assert(0 <= minMatchRating && minMatchRating <= 1);
    assert(maxMatchCount > 0);
    List<Student> students;
    try {
      students = await getStudents();
    } on HttpException {
      return null;
    }

    if (forename == null && surname == null) {
      return null;
    }

    bestMatchesFinder(String name, bool isSurname) {
      var matches = name.bestMatch(students
          .map((student) => isSurname ? student.surName : student.foreName)
          .toList());
      List<Rating> sortedMatches = matches.ratings
        ..sort((Rating a, Rating b) => a.rating!.compareTo(b.rating!));
      var bestMatches = sortedMatches.reversed
          .where((match) => match.rating! >= minMatchRating)
          .take(maxMatchCount)
          .toList();
      var bestMatchesStrings = bestMatches.map((e) => e.target);
      var asStudents = students
          .where((elm) => bestMatchesStrings
          .contains(isSurname ? elm.surName : elm.foreName))
          .toList();
      asStudents.sort((Student a, Student b) => bestMatches
          .firstWhere((r) => r.target == (isSurname ? a.surName : a.foreName))
          .rating!
          .compareTo(bestMatches
          .firstWhere(
              (r) => r.target == (isSurname ? b.surName : b.foreName))
          .rating!));
      return asStudents.reversed.toList();
    }

    var bestForenameMatches, bestSurnameMatches;
    if (forename != null) {
      bestForenameMatches = bestMatchesFinder.call(forename, false);
    }
    if (surname != null) {
      bestSurnameMatches = bestMatchesFinder.call(surname, true);
    }

    return SearchMatches._(bestForenameMatches, bestSurnameMatches);
  }

  Future<List<Period>> getCancellations(IdProvider idProvider,
      {DateTime? startDate, DateTime? endDate, bool useCache = false}) async {
    List<Period> timetable = await getTimetable(idProvider,
        startDate: startDate, endDate: endDate, useCache: useCache);
    timetable.removeWhere((period) => period.isCancelled != true);
    return timetable;
  }

  /// Posts a custom request to the WebUntis HTTP Server. USE WITH CAUTION
  ///
  /// For valid values for the [methodeName] and possible [parameters]
  /// visit the official documentation https://untis-sr.ch/wp-content/uploads/2019/11/2018-09-20-WebUntis_JSON_RPC_API.pdf
  Future<dynamic> customRequest(
      String methodeName, Map<String, Object> parameters) async {
    return await _request(_postify(methodeName, parameters));
  }

  Future<void> quit() async {
    await _request(_postify("logout", {}));
    userId = null;
    userKlasseId = null;
  }

  Future<void> logout() async {
    await quit();
  }

  void clearCache() {
    _cache.removeWhere((key, value) => true);
  }
}

class Period {
  final int id;
  DateTime startTime, endTime;
  final List<IdProvider> klassenIds, teacherIds, subjectIds, roomIds;
  bool isCancelled;
  final String? activityType, code, type, lessonText, statflags;
  String name, teacherName, roomName;

  Period._(
      this.id,
      this.name,
      this.teacherName,
      this.roomName,
      this.startTime,
      this.endTime,
      this.klassenIds,
      this.teacherIds,
      this.subjectIds,
      this.roomIds,
      this.activityType,
      this.isCancelled,
      this.code,
      this.type,
      this.lessonText,
      this.statflags,
      );

  void setName(String name) {
    this.name = name;
  }

  String getStartEndTime() {
    return '${DateFormat('HH:mm').format(startTime)} '
        '- ${DateFormat('HH:mm').format(endTime)}';
  }

  @override
  String toString() => "Period<id:$id, startTime:$startTime, endTime:$endTime, "
      "isCancelled:$isCancelled, klassenIds:$klassenIds, "
      "teacherIds:$teacherIds, subjectIds:$subjectIds, "
      "roomIds:$roomIds, activityType:$activityType, "
      "code:$activityType, type:$type, lessonText:$lessonText, "
      "statflags:$statflags>";
}

class Subject {
  final IdProvider id;
  final String name, longName;

  Subject._(this.id, this.name, this.longName);

  @override
  String toString() => "Subject<id:$id, name:$name, longName:$longName>";
}

class Schoolyear {
  final int id;
  final String name;
  final DateTime startDate, endDate;

  Schoolyear._(this.id, this.name, this.startDate, this.endDate);

  @override
  String toString() =>
      "Schoolyear<id:$id, name:$name, startDate:$startDate, endDate:$startDate>";
}

class Timegrid {
  final List<List<DayTime>>? monday,
      tuesday,
      wednesday,
      thursday,
      friday,
      saturday,
      sunday;

  Timegrid._(
      this.monday,
      this.tuesday,
      this.thursday,
      this.wednesday,
      this.friday,
      this.saturday,
      this.sunday,
      );
  factory Timegrid._fromList(List<List<List<DayTime>>?> list) {
    return Timegrid._(
        list[1], list[2], list[3], list[4], list[5], list[6], list[0]);
  }

  asList() {
    return List.from(
      [monday, tuesday, wednesday, thursday, friday, saturday, sunday],
    );
  }
}

class Student {
  IdProvider id;
  String? key, untisName, foreName, surName, gender;

  Student._(this.id, this.key, this.untisName, this.foreName, this.surName,
      this.gender);

  @override
  String toString() =>
      "Student<${id.toString()}:untisName:$untisName, foreName:$foreName, surName:$surName, gender:$gender, key:$key>";
}

class Teacher {
  IdProvider id;
  String? key, shorthand, foreName, surName, title;
  bool? active;

  Teacher._(this.id, this.key, this.shorthand, this.foreName, this.surName,
      this.title, this.active);

  @override
  String toString() =>
      "Student<${id.toString()}:shorthand:$shorthand, foreName:$foreName, surName:$surName, title:$title, active:$active, key:$key>";
}

class Room {
  IdProvider id;
  String? name, longName, foreColor, backColor;

  Room._(this.id, this.name, this.longName, this.foreColor, this.backColor);

  @override
  String toString() =>
      "Room<${id.toString()}:name:$name, longName:$longName, foreColor:$foreColor, backColor:$backColor>";
}

class Klasse {
  IdProvider id;
  int schoolyearId;
  String? name, longName, foreColor, backColor, did;
  List<IdProvider> teachers;

  Klasse._(this.id, this.schoolyearId, this.name, this.longName, this.foreColor,
      this.backColor, this.teachers);

  @override
  String toString() =>
      "Klasse<${id.toString()}:name:$name, longName:$longName, foreColor:$foreColor, backColor:$backColor, teachers:$teachers>";
}

class DayTime {
  int hour, minute;

  DayTime(this.hour, this.minute);

  @override
  String toString() {
    String addLeadingZeroIfNeeded(int value) {
      if (value < 10) return '0$value';
      return value.toString();
    }

    final String hourLabel = addLeadingZeroIfNeeded(hour);
    final String minuteLabel = addLeadingZeroIfNeeded(minute);

    return '$DayTime($hourLabel:$minuteLabel)';
  }
}

class SearchMatches {
  List<Student>? forenameMatches, surnameMatches;
  SearchMatches._(this.forenameMatches, this.surnameMatches);

  @override
  String toString() =>
      '_SearchMatches<forenameMatches: ${forenameMatches.toString()}\nsurnameMatches: ${surnameMatches.toString()}>';
}

enum IdProviderTypes { klasse, teacher, subject, room, student }

class IdProvider {
  final IdProviderTypes type;
  final int id;

  IdProvider._internal(this.type, this.id);

  factory IdProvider._withType(IdProviderTypes type, int id) {
    return IdProvider._internal(type, id);
  }

  factory IdProvider._(int type, int id) {
    assert(0 < type && type < 6);
    return IdProvider._withType(IdProviderTypes.values[type - 1], id);
  }

  /// Returns a custom IdProvider. USE WITH CAUTION.
  ///
  /// type: 1 = klasse, 2 = teacher, 3 = subject, 4 = room, 5 = student
  factory IdProvider.custom(int type, int id) {
    assert(0 < type && type < 6);
    return IdProvider._withType(IdProviderTypes.values[type - 1], id);
  }

  @override
  String toString() => "IdProvider<type:${type.toString()}, id:$id>";
}

class _CacheEntry {
  final DateTime creationTime;
  final http.Response value;

  _CacheEntry(this.creationTime, this.value);
}
