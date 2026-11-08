/// The HTTP API: three endpoints that turn HTTP requests into BookingService calls and back.
/// It lives outside the four modules and uses only their public contracts. bin/main.dart decides
/// which store the endpoints use, through the unit of work.
library;

import 'api_cache.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'reservations/reservations.dart';
import 'rooms/rooms.dart';

/// Runs one request's work with a BookingService, then saves whatever changed.
typedef UnitOfWork = Future<T> Function<T>(FutureOr<T> Function(BookingService service) work);

const fields = ['guestName', 'guestEmail', 'room', 'checkIn', 'checkOut'];
const bodyDetail = 'The body must be JSON with guestName, guestEmail, room, checkIn and checkOut.';
const dateDetail = 'checkIn and checkOut must be dates such as 2026-11-12.';

Response json(int status, Object? body) =>
    Response(status, body: jsonEncode(body), headers: {'content-type': 'application/json'});

// Problem details (RFC 9457): every error has the same three keys.
Response problem(int status, String title, String detail) => Response(status,
    body: jsonEncode({'title': title, 'status': status, 'detail': detail}),
    headers: {'content-type': 'application/problem+json'});

// A date written exactly like 2026-11-12, otherwise null.
DateTime? parseDate(Object? text) {
  if (text is! String || !RegExp(r'^[0-9]{4}-[0-9]{2}-[0-9]{2}$').hasMatch(text)) return null;
  final day = DateTime.tryParse('${text}T00:00:00Z');
  return day != null && day.toIso8601String().startsWith(text) ? day : null;
}

// Turns a booking answer into an HTTP status code and a JSON body (L04).
Response toHttp(BookingResult result) {
  if (result.outcome == 'Accepted') {
    return json(201, {
      'id': result.reservationId,
      'status': 'Confirmed',
      'notificationFailed': result.notificationFailed
    });
  }
  if (result.outcome == 'Unavailable') {
    return problem(409, 'Unavailable', 'The room is booked for at least one night of this stay.');
  }
  return problem(400, 'InvalidDates', 'checkOut must be after checkIn.');
}

Handler createApi(List<Room> rooms, UnitOfWork unitOfWork, Stats stats, AvailabilityCache cache) {
  final router = Router();
  router.get('/openapi.yaml', (Request request) {
    return Response.ok(File('docs/openapi.yaml').readAsStringSync(),
        headers: {'content-type': 'application/yaml'});
  });

  router.get('/stats', (Request request) {
    return json(200, {
      ...stats.toJson(),
      'avgInternalTimeMs': stats.avgInternalTime, // <-- Добавляем в JSON
    });
  });

  router.get('/rooms/availability', (Request request) async {
    final internalTimer = Stopwatch()..start();
    final query = request.url.queryParameters;
    final checkIn = parseDate(query['checkIn']);
    final checkOut = parseDate(query['checkOut']);
    if (checkIn == null || checkOut == null) return problem(400, 'InvalidDates', dateDetail);
    final stay = DateRange(checkIn, checkOut);
    if (!stay.isValid()) return problem(400, 'InvalidDates', 'checkOut must be after checkIn.');
    final limitText = query['limit'] ?? '20';
    final limit = int.tryParse(limitText) ?? 0;
    if (!RegExp(r'^[0-9]{1,3}$').hasMatch(limitText) || limit < 1 || limit > 100) {
      return problem(400, 'InvalidRequest', 'limit must be a whole number from 1 to 100.');
    }

    stats.searches++;
    // Cache-aside: сначала смотрим в Redis
    final key = cache.key(query['checkIn']!, query['checkOut']!);
    final cached = await cache.get(key);
    final List<Room> free;

    if (cached != null) {
      stats.cacheHits++;
      final numbers = cached.split(',');
      free = rooms.where((room) => numbers.contains(room.number)).toList();
    } else {
      stats.cacheMisses++;
      free = await unitOfWork((service) => service.findFreeRooms(stay));
      await cache.set(key, (free.map((room) => room.number).toList()..sort()).join(','));
    }

    final after = query['after'] ?? '';
    final rest = free.where((room) => room.number.compareTo(after) > 0).toList()
      ..sort((a, b) => a.number.compareTo(b.number));
    final page = rest.take(limit).toList();
    internalTimer.stop();
    stats.totalInternalTime += internalTimer.elapsedMicroseconds / 1000;
    stats.internalCount++;
    // print('⏱️ Внутреннее время сервера: ${internalTimer.elapsedMicroseconds / 1000} мс');

    return json(200, {
      'checkIn': query['checkIn'],
      'checkOut': query['checkOut'],
      'rooms': [
        for (final room in page) {'number': room.number, 'type': room.type}
      ],
      'next': rest.length > page.length ? page.last.number : null,
    });
  });

  router.post('/reservations', (Request request) async {
    if (request.mimeType != 'application/json') return problem(400, 'InvalidRequest', bodyDetail);
    Object? json;
    try {
      json = jsonDecode(await request.readAsString());
    } on FormatException {
      return problem(400, 'InvalidRequest', bodyDetail);
    }
    final body = json is Map ? json : const {};
    if (!fields.every((field) => body[field] is String && body[field] != '')) {
      return problem(400, 'InvalidRequest', bodyDetail);
    }
    final checkIn = parseDate(body['checkIn']);
    final checkOut = parseDate(body['checkOut']);
    if (checkIn == null || checkOut == null) return problem(400, 'InvalidDates', dateDetail);
    final room = rooms.where((room) => room.number == body['room']).firstOrNull;
    if (room == null) return problem(400, 'UnknownRoom', 'There is no room ${body['room']}.');

    final guest = Guest(body['guestName'] as String, body['guestEmail'] as String);
    final result =
        await unitOfWork((service) => service.reserve(guest, room, DateRange(checkIn, checkOut)));

    if (result.outcome == 'Accepted') {
      await cache.invalidate();
    }

    return toHttp(result);
  });

  router.delete('/reservations/<id>', (Request request, String id) async {
    final cancelled = await unitOfWork((service) => service.cancel(id));
    if (!cancelled) return problem(404, 'NotFound', 'There is no confirmed reservation $id.');

    await cache.invalidate(); // <--- ДОБАВИТЬ ЭТО

    return Response(204);
  });

  return router.call;
}

// Счетчики для GET /stats. В Dart ++ работает точно, так как запросы идут в одном изоляте.
class Stats {
  int searches = 0;
  int databaseQueries = 0;
  int cacheHits = 0;
  int cacheMisses = 0;

  // Новые поля для замера
  double totalInternalTime = 0.0;
  int internalCount = 0;

  Map<String, int> toJson() => {
        'searches': searches,
        'databaseQueries': databaseQueries,
        'cacheHits': cacheHits,
        'cacheMisses': cacheMisses,
      };

  // Метод для получения среднего внутреннего времени
  double get avgInternalTime => internalCount == 0 ? 0.0 : totalInternalTime / internalCount;
}

// Обертка над хранилищем, которая считает каждый запрос к базе данных.
class CountingReservationStore implements ReservationStore {
  CountingReservationStore(this._store, this._stats);

  final ReservationStore _store;
  final Stats _stats;

  @override
  FutureOr<int> get count {
    _stats.databaseQueries++;
    return _store.count;
  }

  @override
  FutureOr<bool> hasOverlap(Room room, DateRange stay) {
    _stats.databaseQueries++;
    return _store.hasOverlap(room, stay);
  }

  @override
  FutureOr<void> save(Reservation reservation) {
    _stats.databaseQueries++;
    return _store.save(reservation);
  }

  @override
  FutureOr<Reservation?> find(String id) {
    _stats.databaseQueries++;
    return _store.find(id);
  }

  @override
  FutureOr<int> countConfirmed(Room room, DateRange stay) {
    _stats.databaseQueries++;
    return _store.countConfirmed(room, stay);
  }
}
