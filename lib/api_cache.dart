// lib/api_cache.dart
import 'package:redis/redis.dart' show Command;

const ttlSeconds = 30;
const versionKey = 'availability:version';

// Контракт для работы с Redis (чтобы в тестах можно было подставить словарь)
abstract interface class KeyValueStore {
  Future<String?> get(String key);
  Future<void> set(String key, String value, int ttlSeconds);
  Future<void> increment(String key);
}

// Реальная работа с Redis
class RedisKeyValueStore implements KeyValueStore {
  RedisKeyValueStore(this._redis);
  final Command _redis;

  @override
  Future<String?> get(String key) async => await _redis.send_object(['GET', key]) as String?;

  @override
  Future<void> set(String key, String value, int ttlSeconds) =>
      _redis.send_object(['SET', key, value, 'EX', '$ttlSeconds']);

  @override
  Future<void> increment(String key) => _redis.send_object(['INCR', key]);
}

// Сам кэш (Cache-aside)

 // Сам кэш (Cache-aside)
class AvailabilityCache {
  AvailabilityCache(this._store, this._version);
  final KeyValueStore _store;
  int _version; // <--- Храним версию локально в памяти

  // Фабричный метод для создания кэша с загрузкой начальной версии
  static Future<AvailabilityCache> create(KeyValueStore store) async {
    final v = await store.get(versionKey) ?? '0';
    return AvailabilityCache(store, int.parse(v));
  }

  // Теперь метод key синхронный и не делает запросов в Redis
  String key(String checkIn, String checkOut) {
    return 'availability:v$_version:$checkIn:$checkOut';
  }

  Future<String?> get(String key) => _store.get(key);

  Future<void> set(String key, String roomNumbers) => _store.set(key, roomNumbers, ttlSeconds);

  Future<void> invalidate() async {
    _version++; // Обновляем локально
    await _store.increment(versionKey); // И в Redis (на случай масштабирования)
  }
}