// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:in_app_purchase_platform_interface/in_app_purchase_platform_interface.dart';

import '../in_app_purchase_storekit.dart';
import '../store_kit_2_wrappers.dart';
import '../store_kit_wrappers.dart';

/// [IAPError.code] code for failed purchases.
const String kPurchaseErrorCode = 'purchase_error';

/// Indicates store front is Apple AppStore.
const String kIAPSource = 'app_store';

/// An [InAppPurchasePlatform] that wraps StoreKit.
///
/// This translates various `StoreKit` calls and responses into the
/// generic plugin API.
class InAppPurchaseStoreKitPlatform extends InAppPurchasePlatform {
  /// Creates an [InAppPurchaseStoreKitPlatform] object.
  ///
  /// This constructor should only be used for testing, for any other purpose
  /// get the connection from the [instance] getter.
  @visibleForTesting
  InAppPurchaseStoreKitPlatform();

  /// StoreKit1
  static late SKPaymentQueueWrapper _skPaymentQueueWrapper;
  static late _TransactionObserver _sk1transactionObserver;

  /// StoreKit2
  static late SK2TransactionObserverWrapper _sk2transactionObserver;

  @override
  Stream<List<PurchaseDetails>> get purchaseStream => _sk2transactionObserver.transactionsCreatedController.stream;

  /// Callback handler for transaction status changes.
  @visibleForTesting
  static SKTransactionObserverWrapper get observer => _sk1transactionObserver;

  /// Callback handler for transaction status changes for StoreKit2 transactions
  @visibleForTesting
  static SK2TransactionObserverWrapper get sk2TransactionObserver =>
      _sk2transactionObserver;

  /// Registers this class as the default instance of [InAppPurchasePlatform].
  static void registerPlatform() {
    // Register the [InAppPurchaseStoreKitPlatformAddition] containing
    // StoreKit-specific functionality.
    InAppPurchasePlatformAddition.instance =
        InAppPurchaseStoreKitPlatformAddition();

    // Register the platform-specific implementation of the idiomatic
    // InAppPurchase API.
    InAppPurchasePlatform.instance = InAppPurchaseStoreKitPlatform();

    _skPaymentQueueWrapper = SKPaymentQueueWrapper();

    final updateController2 =
        StreamController<List<PurchaseDetails>>.broadcast(
          onListen: () => SK2Transaction.startListeningToTransactions(),
          onCancel: () => SK2Transaction.stopListeningToTransactions(),
        );
    _sk2transactionObserver = SK2TransactionObserverWrapper(
      transactionsCreatedController: updateController2,
    );
    InAppPurchase2CallbackAPI.setUp(_sk2transactionObserver);
  }

  @override
  Future<bool> isAvailable() =>
      AppStore().canMakePayments();

  /// Initiates the purchase flow for a non-consumable product.
  ///
  /// If StoreKit2 is enabled (`_useStoreKit2` is true), this method uses
  /// the StoreKit2 APIs to handle the purchase, including support for
  /// win-back offers, promotional offers, or any future StoreKit2-specific
  /// offer types. Otherwise, it falls back to StoreKit1 (`SKPaymentQueue`).
  ///
  /// The [purchaseParam] can be an instance of:
  /// - [Sk2PurchaseParam] — to include StoreKit2-specific fields like:
  ///   - [winBackOfferId]: Applies a win-back offer.
  ///   - [promotionalOffer]: Applies a promotional offer (requires a valid signature).
  ///
  /// - [AppStorePurchaseParam] — for StoreKit1 flows using `SKPaymentQueue`.
  ///
  /// - [PurchaseParam] — the generic, cross-platform parameter for purchases
  ///   without any platform-specific fields.
  ///
  /// Returns `true` if the purchase flow was initiated successfully.
  /// Note that a `true` return value does not mean the purchase was completed.
  /// The final purchase result (success, failure, or pending) is delivered
  /// via the purchase updates stream.
  ///
  /// Throws a [PlatformException] if the purchase could not be initiated due
  /// to configuration issues or platform errors.
  ///
  /// Example:
  /// ```dart
  /// final productDetails = ...; // Obtained from queryProductDetails
  ///
  /// // Example using StoreKit 2:
  /// final purchaseParamSk2 = Sk2PurchaseParam(
  ///   productDetails: productDetails,
  ///   promotionalOffer: myPromotionalOffer,
  /// );
  /// await InAppPurchase.instance.buyNonConsumable(
  ///   purchaseParam: purchaseParamSk2,
  /// );
  ///
  /// // Example using StoreKit 1 fallback:
  /// final purchaseParamSk1 = AppStorePurchaseParam(
  ///   productDetails: productDetails,
  ///   quantity: 1,
  /// );
  /// await InAppPurchase.instance.buyNonConsumable(
  ///   purchaseParam: purchaseParamSk1,
  /// );
  ///
  /// // Example using the generic PurchaseParam (works on any store):
  /// final purchaseParamGeneric = PurchaseParam(
  ///   productDetails: productDetails,
  /// );
  /// await InAppPurchase.instance.buyNonConsumable(
  ///   purchaseParam: purchaseParamGeneric,
  /// );
  /// ```
  @override
  Future<BuyResponse> buyNonConsumable({required PurchaseParam purchaseParam}) async {

    try {
      final SK2ProductPurchaseOptions options;

      if (purchaseParam is Sk2PurchaseParam) {
        options = SK2ProductPurchaseOptions(
          appAccountToken: purchaseParam.applicationUserName,
          quantity: purchaseParam.quantity,
          winBackOfferId: purchaseParam.winBackOfferId,
          promotionalOffer: _convertPromotionalOffer(
            purchaseParam.promotionalOffer,
          ),
        );
      } else {
        options = SK2ProductPurchaseOptions(
          quantity: purchaseParam is AppStorePurchaseParam
              ? purchaseParam.quantity
              : 1,
          appAccountToken: purchaseParam.applicationUserName,
        );
      }

      final SK2ProductPurchaseResult result = await SK2Product.purchase(
        purchaseParam.productDetails.id,
        options: options,
      );

      return BuyResponse(type: switch (result) {
        SK2ProductPurchaseResult.success => BuyResponseType.ok,
        SK2ProductPurchaseResult.unverified => BuyResponseType.unverified,
        SK2ProductPurchaseResult.userCancelled => BuyResponseType.userCanceled,
        SK2ProductPurchaseResult.pending => BuyResponseType.pending,
      });
    } catch (e, s) {
      return BuyResponse(error: e, stack: s);
    }
  }

  static SK2SubscriptionOfferPurchaseMessage? _convertPromotionalOffer(
    SK2PromotionalOffer? promotionalOffer,
  ) {
    if (promotionalOffer == null) {
      return null;
    }

    return SK2SubscriptionOfferPurchaseMessage(
      promotionalOfferSignature: SK2SubscriptionOfferSignatureMessage(
        keyID: promotionalOffer.signature.keyID,
        signature: promotionalOffer.signature.signature,
        nonce: promotionalOffer.signature.nonce,
        timestamp: promotionalOffer.signature.timestamp,
      ),
      promotionalOfferId: promotionalOffer.offerId,
    );
  }

  @override
  Future<BuyResponse> buyConsumable({
    required PurchaseParam purchaseParam,
    bool autoConsume = true,
  }) async {
    assert(autoConsume, 'On iOS, we should always auto consume');
    return await buyNonConsumable(purchaseParam: purchaseParam);
  }

  @override
  Future<void> completePurchase(PurchaseDetails purchase) {
    assert(
      purchase is AppStorePurchaseDetails || purchase is SK2PurchaseDetails,
      'On iOS, the `purchase` should always be of type `AppStorePurchaseDetails`.',
    );

    return SK2Transaction.finish(int.parse(purchase.purchaseID!));
  }

  @override
  Future<void> restorePurchases({String? applicationUserName}) async =>
      SK2Transaction.restorePurchases();

  /// Query the product detail list.
  ///
  /// This method only returns [ProductDetailsResponse].
  /// To get detailed Store Kit product list, use [SkProductResponseWrapper.startProductRequest]
  /// to get the [SKProductResponseWrapper].
  @override
  Future<ProductDetailsResponse> queryProductDetails(
    Set<String> identifiers,
  ) async {
    var products = <SK2Product>[];
    Set<String> invalidProductIdentifiers;
    PlatformException? exception;
    try {
      products = await SK2Product.products(identifiers.toList());
      // Storekit 2 no longer automatically returns a list of invalid identifiers,
      // so get the difference between given identifiers and returned products
      invalidProductIdentifiers = identifiers.difference(
        products.map((SK2Product product) => product.id).toSet(),
      );
    } on PlatformException catch (e) {
      exception = e;
      invalidProductIdentifiers = identifiers;
    }
    List<AppStoreProduct2Details> productDetails;
    productDetails = products
        .map(
          (SK2Product productWrapper) =>
              AppStoreProduct2Details.fromSK2Product(productWrapper),
        )
        .toList();
    final response = ProductDetailsResponse(
      productDetails: productDetails,
      notFoundIDs: invalidProductIdentifiers.toList(),
      error: exception == null
          ? null
          : IAPError(
              source: kIAPSource,
              code: exception.code,
              message: exception.message ?? '',
              details: exception.details,
            ),
    );
    return response;
  }

  /// Returns the country code from SKStoreFrontWrapper.
  ///
  /// Uses the ISO 3166-1 Alpha-3 country code representation.
  /// See: https://developer.apple.com/documentation/storekit/skstorefront?language=objc
  @override
  Future<String> countryCode() async =>
      Storefront().countryCode();

  /// Use countryCode instead.
  @Deprecated('Use countryCode')
  Future<String?> getCountryCode() => countryCode();

  // /// StoreKit 2 is now the default.
  // @Deprecated('StoreKit 2 is now the default')
  // static Future<bool> enableStoreKit2() async {
  //   return true;
  // }

  // /// Call this before `registerPlatform` to re-enable StoreKit1
  // @Deprecated('Please note that StoreKit 1 will be removed in the future.')
  // static Future<bool> enableStoreKit1() async {
  //   throw StateError('cannot enable Store Kit1')
  //   return false;
  // }

  /// Checks if the user is eligible for an introductory offer (StoreKit2 only).
  ///
  /// Throws [PlatformException] if StoreKit2 is not enabled, if the product is not found,
  /// if the product is not a subscription, or if any error occurs during the eligibility check.
  ///
  /// [PlatformException.code] can be one of:
  /// - `storekit2_not_enabled`
  /// - `storekit2_failed_to_fetch_product`
  /// - `storekit2_not_subscription`
  /// - `storekit2_eligibility_check_failed`
  Future<bool> isIntroductoryOfferEligible(String productId) async {

    final bool eligibility = await SK2Product.isIntroductoryOfferEligible(
      productId,
    );

    return eligibility;
  }

  /// Checks if the user is eligible for a specific win back offer (StoreKit2 only).
  ///
  /// Throws [PlatformException] if StoreKit2 is not enabled, if the product is not found,
  /// if the product is not a subscription, or if any error occurs during the eligibility check.
  ///
  /// [PlatformException.code] can be one of:
  /// - `storekit2_not_enabled`
  /// - `storekit2_unsupported_platform_version`
  /// - `storekit2_failed_to_fetch_product`
  /// - `storekit2_not_subscription`
  /// - `storekit2_eligibility_check_failed`
  Future<bool> isWinBackOfferEligible(String productId, String offerId) async {
    final bool eligibility = await SK2Product.isWinBackOfferEligible(
      productId,
      offerId,
    );

    return eligibility;
  }
}

enum _TransactionRestoreState {
  notRunning,
  waitingForTransactions,
  receivedTransaction,
}

class _TransactionObserver implements SKTransactionObserverWrapper {
  _TransactionObserver(this.purchaseUpdatedController);

  final StreamController<List<PurchaseDetails>> purchaseUpdatedController;

  Completer<void>? _restoreCompleter;
  late String _receiptData;
  _TransactionRestoreState _transactionRestoreState =
      _TransactionRestoreState.notRunning;

  Future<void> restoreTransactions({
    required SKPaymentQueueWrapper queue,
    String? applicationUserName,
  }) {
    _transactionRestoreState = _TransactionRestoreState.waitingForTransactions;
    _restoreCompleter = Completer<void>();
    queue.restoreTransactions(applicationUserName: applicationUserName);
    return _restoreCompleter!.future;
  }

  void cleanUpRestoredTransactions() {
    _restoreCompleter = null;
  }

  @override
  void updatedTransactions({
    required List<SKPaymentTransactionWrapper> transactions,
  }) {
    _handleTransationUpdates(transactions);
  }

  @override
  void removedTransactions({
    required List<SKPaymentTransactionWrapper> transactions,
  }) {}

  /// Triggered when there is an error while restoring transactions.
  @override
  void restoreCompletedTransactionsFailed({required SKError error}) {
    _restoreCompleter!.completeError(error);
    _transactionRestoreState = _TransactionRestoreState.notRunning;
  }

  @override
  void paymentQueueRestoreCompletedTransactionsFinished() {
    _restoreCompleter!.complete();

    // If no restored transactions were received during the restore session
    // emit an empty list of purchase details to inform listeners that the
    // restore session finished without any results.
    if (_transactionRestoreState ==
        _TransactionRestoreState.waitingForTransactions) {
      purchaseUpdatedController.add(<PurchaseDetails>[]);
    }

    _transactionRestoreState = _TransactionRestoreState.notRunning;
  }

  @override
  bool shouldAddStorePayment({
    required SKPaymentWrapper payment,
    required SKProductWrapper product,
  }) {
    // In this unified API, we always return true to keep it consistent with the behavior on Google Play.
    return true;
  }

  Future<String> getReceiptData() async {
    try {
      _receiptData = await SKReceiptManager.retrieveReceiptData();
    } catch (e) {
      _receiptData = '';
    }
    return _receiptData;
  }

  Future<void> _handleTransationUpdates(
    List<SKPaymentTransactionWrapper> transactions,
  ) async {
    if (_transactionRestoreState ==
            _TransactionRestoreState.waitingForTransactions &&
        transactions.any(
          (SKPaymentTransactionWrapper transaction) =>
              transaction.transactionState ==
              SKPaymentTransactionStateWrapper.restored,
        )) {
      _transactionRestoreState = _TransactionRestoreState.receivedTransaction;
    }

    final String receiptData = await getReceiptData();
    final List<PurchaseDetails> purchases = transactions
        .map(
          (SKPaymentTransactionWrapper transaction) =>
              AppStorePurchaseDetails.fromSKTransaction(
                transaction,
                receiptData,
              ),
        )
        .toList();

    purchaseUpdatedController.add(purchases);
  }
}
