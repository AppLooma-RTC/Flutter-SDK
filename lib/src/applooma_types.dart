/// Roles supported by AppLooma RTC channels.
enum AppRole { host, cohost, audience }

/// Connection lifecycle states.
enum AppConnectionState { connecting, connected, reconnecting, disconnected }

/// Options for joining a channel.
class AppJoinOptions {
  final AppRole role;

  /// Auto-enable camera on join (ignored for audience).
  final bool camera;

  /// Auto-enable microphone on join (ignored for audience).
  final bool microphone;

  const AppJoinOptions({
    this.role = AppRole.host,
    this.camera = false,
    this.microphone = true,
  });
}

/// A virtual gift broadcast to everyone in the channel.
///
/// Sent from your server with `POST /v1/gifts/send`; every client in the room
/// receives it on [AppEngine.onGiftReceived]. Shape matches the other SDKs.
class AppGiftEvent {
  final String txId;
  final String giftId;
  final String giftName;
  final String imageUrl;
  final int coinPrice;
  final String sender;
  final String receiver;
  final int quantity;

  const AppGiftEvent({
    required this.txId,
    required this.giftId,
    required this.giftName,
    required this.imageUrl,
    required this.coinPrice,
    required this.sender,
    required this.receiver,
    required this.quantity,
  });

  /// Returns null when the payload is not a gift event.
  static AppGiftEvent? fromJson(Map<String, dynamic> msg) {
    try {
      if (msg['type'] != 'applooma.gift') return null;
      final gift = Map<String, dynamic>.from(msg['gift'] as Map);
      return AppGiftEvent(
        txId: msg['txId'] as String,
        giftId: gift['id'] as String? ?? '',
        giftName: gift['name'] as String,
        imageUrl: gift['imageUrl'] as String,
        coinPrice: (gift['coinPrice'] as num?)?.toInt() ?? 0,
        sender: msg['sender'] as String,
        receiver: msg['receiver'] as String,
        quantity: (msg['quantity'] as num?)?.toInt() ?? 1,
      );
    } catch (_) {
      return null;
    }
  }
}
