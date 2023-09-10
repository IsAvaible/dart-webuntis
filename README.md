# dart-webuntis

An asynchrous WebUntis API wrapper written in Dart.

# Usage

Attention: Each method must be properly awaited in an asynchronous fashion. This rather annoying
circumstance is inherited by the usage of the http package, but should
help to design fast & responsive UIs.

Starting off, add this package to the dependencies of your pubspec.yaml file:

```yaml
dart_webuntis:
  git:
    url: git://github.com/IsAvaible/dart-webuntis.git
    ref: main
```

The basic tool used to interact with the API is the Session object.

```dart
// .init(server, school, username, password, Optional: useragent)
Session mySession = await
Session.init
("demo.server.com", "demo_school", "demo_user",
"demo_pass
"
)
// The ID of the account which credentials you used should now be available over the .userId attribute
var myId = session.userId;
// Alternatively you can also search for a student
var myId = (await mySession.searchStudent("demo_forename", "demo_surname"))!.surnameMatches!
[
0
]
.
id;
```

Basic methods act just as you expect them to.

```dart
// To get cancellations for a specific day, simply call the .getCancellations method with a startDate
List<Period> cancellationsTmwr = await
mySession.getCancellations
(
mySession.userId, startDate: DateTime.now().add(Duration(days: 1)));
// The same principle applies to the .getTimetable method, startDate and endDate (inclusive) are optional and will default to the current day
List<Period> timetable = await mySession.
getTimetable
(
mySession
.
userId
);
```

Some methods like getStudent will cache their result for 30minutes by default.

```dart
// (To disable this set the named parameter useCache to false)
var students = await

getStudents();
// .. 12 minutes passed ..
students =

await getStudents(); // Cached value is being reused to increase performance
// You can modify the maximum amount of requests stored in cache and the dispose time in minutes, to alter the cache behaviour
mySession.cacheDisposeTime = 60; // Cached values will now stay available for 60 minutes
```

You want to program a timetable app? These methods might be useful.

```dart
// Get a timegrid that specifies the period time spans for each day
Timegrid myTimegrid = await
mySession.getTimegrid
();
// Get the timetable of the current week
DateTime mostRecentWeekday(DateTime date, int weekday) =>
    DateTime(date.year, date.month, date.day - (date.weekday - weekday) % 7);
DateTime monday = mostRecentWeekday(DateTime.now(), DateTime.monday),
    friday = mostRecentWeekday(DateTime.now(), DateTime.friday);
var myTimetable = await
mySession.getTimetable
(
myId, startDate: monday, endDate: friday);
```

If a function you want to use is not implemented by the wrapper yet, you can use the customRequest
method.
This will return whatever the response of the API was as a JsonDecoded Object. This will be either a
Map or a List most of the time.

```dart

var teachers = await
mySession.customRequest
("getTeachers", {});
// You may use the result with a custom IdProvider or similar
var teacherIds = teachers.map((teacher) => IdProvider.custom(2, teacher["id"
]
)
)
```

# Disclaimer

Please be aware that this wrapper is extremely bare bones, as I only implemented the methods that I
think will be useful in app development.
This is in no way a sophisticated approach of properly wrapping the clunky HTTP API provided by
WebUntis, but it should do the job.
If you feel inspired to contribute to this project, please do so, as it may help other developers
facing the same limitations! 
