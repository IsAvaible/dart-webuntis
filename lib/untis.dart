library dart_webuntis;

import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:string_similarity/string_similarity.dart';

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
//  ```
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
      response = await _http.post(url,
          body: requestBodyAsString,
          headers: {"Cookie": "JSESSIONID=$_sessionId"});
    }

    _cache[requestBodyAsString] = _CacheEntry(DateTime.now(), response);
    if (_cache.length > cacheLengthMaximum) {
      _cache.remove(_cache.keys.take(1).toList()[0].toString());
    }

    LinkedHashMap<String, dynamic> responseBody = jsonDecode(response.body);

    if (response.statusCode != 200 || responseBody.containsKey("error")) {
      int untisErrorCode = responseBody["error"]["code"];
      String untisErrorText = untisErrorCode == -8520
          ? "\nYou need to authenticate with .login() first."
          : "";
      throw HttpException(
          "An exception occurred while communicating with the WebUntis API: ${responseBody["error"]}$untisErrorText");
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
      "jsonrpc": "2.0"
    };
    return postBody;
  }

  Future<void> login() async {
    var result = await _request(_postify("authenticate",
        {"user": username, "password": _password, "client": userAgent}));
    _sessionId = result["sessionId"] as String;
    if (result.containsKey("personId")) {
      userId =
          IdProvider._(result["personType"] as int, result["personId"] as int);
    }
    if (result.containsKey("klasseId")) {
      userKlasseId = IdProvider._withType(
          IdProviderTypes.KLASSE, result["klasseId"] as int);
    }
  }

  Future<List<Period>> getTimetable(IdProvider idProvider,
      {DateTime? startDate, DateTime? endDate, bool useCache = false}) async {
    var id = idProvider.id, type = idProvider.type.index + 1;

    startDate = startDate ?? DateTime.now();
    endDate = endDate ?? startDate;
    if (startDate.compareTo(endDate) == 1) {
      throw Exception("startDate must be equal to or before the endDate.");
    }
    convYearMonth(DateTime dateTime) =>
        dateTime.toIso8601String().substring(0, 10).replaceAll("-", "");

    var rawTimetable = await _request(
        _postify("getTimetable", {
          "id": id,
          "type": type,
          "startDate": convYearMonth(startDate),
          "endDate": convYearMonth(endDate)
        }),
        useCache: useCache);

    return _parseTimetable(rawTimetable);
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
        "statflags"
      ],
          value: (key) => rawTimetable[index].containsKey(key)
              ? rawTimetable[index][key]
              : null);
      return Period._(
        period["id"] as int,
        DateTime.parse(
            "${period["date"]} ${period["startTime"].toString().padLeft(4, "0")}"),
        DateTime.parse(
            "${period["date"]} ${period["endTime"].toString().padLeft(4, "0")}"),
        List.generate(
            period["kl"].length,
            (index) => IdProvider._withType(
                IdProviderTypes.KLASSE, period["kl"][index]["id"])),
        List.generate(
            period["te"].length,
            (index) => IdProvider._withType(
                IdProviderTypes.KLASSE, period["te"][index]["id"])),
        List.generate(
            period["su"].length,
            (index) => IdProvider._withType(
                IdProviderTypes.KLASSE, period["su"][index]["id"])),
        List.generate(
            period["ro"].length,
            (index) => IdProvider._withType(
                IdProviderTypes.KLASSE, period["ro"][index]["id"])),
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
          IdProvider._internal(IdProviderTypes.STUDENT, subject["id"]),
          subject["name"],
          subject["longName"],
          subject["alternateName"]);
    });
  }

  Future<TimeGrid> getTimeGrid({bool useCache = true}) async {
    List<dynamic> rawTimeGrid =
        await _request(_postify("getTimegridUnits", {}), useCache: useCache);
    return _parseTimeGrid(rawTimeGrid);
  }

  TimeGrid _parseTimeGrid(List<dynamic> rawTimeGrid) {
    return TimeGrid._fromList(List.generate(7, (day) {
      if (rawTimeGrid.map((e) => e["day"]).contains(day)) {
        var dayDict =
            rawTimeGrid.firstWhere((element) => (element["day"] == day));
        List<dynamic> dayData = dayDict["timeUnits"];

        List.generate(
            dayData.length,
            (timePeriod) => List.generate(2, (periodBorder) {
                  String border =
                      List.from(["startTime", "endTime"])[periodBorder];
                  String time =
                      dayData[timePeriod][border].toString().padLeft(4, "0");
                  String hour = time.substring(0, 2),
                      minute = time.substring(2, 4);
                  return DayTime(int.parse(hour), int.parse(minute));
                }));
      } else {
        return null;
      }
      return null;
    }));
  }

  Future<SchoolYear> getCurrentSchoolYear({bool useCache = true}) async {
    Map<String, dynamic> rawSchoolYear =
        await _request(_postify("getCurrentSchoolyear", {}));
    return _parseSchoolYear(rawSchoolYear);
  }

  Future<List<SchoolYear>> getSchoolYears({bool useCache = true}) async {
    List<dynamic> rawSchoolYears =
        await _request(_postify("getSchoolyears", {}));
    return List.generate(rawSchoolYears.length,
        (year) => _parseSchoolYear(rawSchoolYears[year]));
  }

  SchoolYear _parseSchoolYear(Map rawSchoolYear) {
    return SchoolYear._(
        rawSchoolYear["id"],
        rawSchoolYear["name"],
        DateTime.parse(rawSchoolYear["startDate"].toString()),
        DateTime.parse(rawSchoolYear["endDate"].toString()));
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
        IdProvider._withType(IdProviderTypes.STUDENT, student["id"]),
        student.containsKey("key") ? student["key"] : null,
        student.containsKey("name") ? student["name"] : null,
        student.containsKey("foreName") ? student["foreName"] : null,
        student.containsKey("longName") ? student["longName"] : null,
        student.containsKey("gender") ? student["gender"] : null,
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
        IdProvider._withType(IdProviderTypes.ROOM, room["id"]),
        room.containsKey("name") ? room["name"] : null,
        room.containsKey("longName") ? room["longName"] : null,
        room.containsKey("foreColor") ? room["foreColor"] : null,
        room.containsKey("backColor") ? room["backColor"] : null,
      );
    });
  }

  Future<List<Klasse>> getKlassen(int schoolYearId,
      {bool useCache = true}) async {
    List<dynamic> rawKlassen = await _request(
        _postify("getKlassen", {"schoolyearId": schoolYearId}),
        useCache: useCache);
    return _parseKlassen(rawKlassen, schoolYearId);
  }

  List<Klasse> _parseKlassen(List<dynamic> rawKlassen, int schoolYearId) {
    return List.generate(rawKlassen.length, (index) {
      Map klasse = rawKlassen[index];
      var teachers = klasse.keys.where((e) => e.startsWith("teacher")).toList();
      return Klasse._(
          IdProvider._withType(IdProviderTypes.KLASSE, klasse["id"]),
          schoolYearId,
          klasse.containsKey("name") ? klasse["name"] : null,
          klasse.containsKey("longName") ? klasse["longName"] : null,
          klasse.containsKey("foreColor") ? klasse["foreColor"] : null,
          klasse.containsKey("backColor") ? klasse["backColor"] : null,
          List.generate(
              teachers.length,
              (i) => IdProvider._withType(
                  IdProviderTypes.TEACHER, klasse[teachers[i]])));
    });
  }

  Future<IdProvider?> searchPerson(
      String forename, String surname, bool isTeacher,
      {String birthData = "0"}) async {
    int response = await _request(_postify("getPersonId", {
      "type": isTeacher ? 2 : 5,
      "sn": surname,
      "fn": forename,
      "dob": birthData
    }));
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

    bool searchForForename = forename != null;

    List<Student> findBestMatches(String name, bool isSurname) {
      BestMatch matches = name.bestMatch(
        students
            .map((student) => isSurname ? student.surName : student.foreName)
            .toList(),
      );

      List<Rating> sortedMatches = matches.ratings
        ..sort((a, b) => a.rating!.compareTo(b.rating!));

      // Highest rating is index 0
      List<Rating> bestMatches = sortedMatches.reversed
          .where((match) => match.rating! >= minMatchRating)
          .take(maxMatchCount)
          .toList();

      Iterable<String?> bestMatchingNames = bestMatches.map((e) => e.target);

      List<Student> bestMatchingStudents = students
          .where((student) => bestMatchingNames
              .contains(isSurname ? student.surName : student.foreName))
          .toList();

      // This method accounts for multiple fore/sur names in the bestMatches
      double getMatchingStudentRating(Student std) => bestMatches
          .firstWhere(
              (r) => r.target == (isSurname ? std.surName : std.foreName))
          .rating!;

      bestMatchingStudents.sort((Student a, Student b) =>
          getMatchingStudentRating(a).compareTo(getMatchingStudentRating(b)));

      return bestMatchingStudents.reversed.toList();
    }

    if (searchForForename) {
      return SearchMatches._(findBestMatches(forename, false), null);
    } else {
      return SearchMatches._(null, findBestMatches(surname!, true));
    }
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
  final DateTime startTime, endTime;
  final List<IdProvider> klassenIds, teacherIds, subjectIds, roomIds;
  final bool isCancelled;
  final String? activityType, code, type, lessonText, statflags;

  Period._(
      this.id,
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
      this.statflags);

  @override
  String toString() =>
      "Period<id:$id, startTime:$startTime, endTime:$endTime, isCancelled:$isCancelled, klassenIds:$klassenIds, teacherIds:$teacherIds, subjectIds:$subjectIds, roomIds:$roomIds, activityType:$activityType, code:$activityType, type:$type, lessonText:$lessonText, statflags:$statflags>";
}

class Subject {
  final IdProvider id;
  final String name, longName, alternateName;

  Subject._(this.id, this.name, this.longName, this.alternateName);

  @override
  String toString() => "Subject<id:$id, name:$name, longName:$longName";
}

class SchoolYear {
  final int id;
  final String name;
  final DateTime startDate, endDate;

  SchoolYear._(this.id, this.name, this.startDate, this.endDate);

  @override
  String toString() =>
      "SchoolYear<id:$id, name:$name, startDate:$startDate, endDate:$startDate>";
}

class TimeGrid {
  final List<List<DayTime>>? monday,
      tuesday,
      wednesday,
      thursday,
      friday,
      saturday,
      sunday;

  TimeGrid._(this.monday, this.tuesday, this.thursday, this.wednesday,
      this.friday, this.saturday, this.sunday);

  factory TimeGrid._fromList(List<List<List<DayTime>>?> list) {
    return TimeGrid._(
        list[1], list[2], list[3], list[4], list[5], list[6], list[0]);
  }

  asList() {
    return List.from(
        [monday, tuesday, wednesday, thursday, friday, saturday, sunday]);
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
  int schoolYearId;
  String? name, longName, foreColor, backColor, did;
  List<IdProvider> teachers;

  Klasse._(this.id, this.schoolYearId, this.name, this.longName, this.foreColor,
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
      '_SearchMatches<forenameMatches: $forenameMatches\nsurnameMatches: $surnameMatches>';
}

enum IdProviderTypes { KLASSE, TEACHER, SUBJECT, ROOM, STUDENT }

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
