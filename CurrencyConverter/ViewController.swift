//
//  ViewController.swift
//  CurrencyConverter
//
//  Created by Yongha Yoo (inkyfox) on 2016. 9. 21..
//  Copyright © 2016년 Gen X Hippies Company. All rights reserved.
//

import UIKit
import RxCocoa
import RxSwift

class ViewController: UIViewController {

    @IBOutlet weak var reloadButton: UIBarButtonItem!
    @IBOutlet weak var upperCurrencyView: CurrencyView!
    @IBOutlet weak var lowerCurrencyView: CurrencyView!
    @IBOutlet weak var swapHButton: UIButton!
    @IBOutlet weak var swapVButton: UIButton!
    
    fileprivate let disposeBag = DisposeBag()
    fileprivate var numberUnlocked = true
    fileprivate var reloadBag = Variable<DisposeBag?>(nil)
    
    override func viewDidLoad() {
        super.viewDidLoad()

        setupSubscriptions()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        CurrencyNotification.checkReload.post()
    }
    
}

extension ViewController {
    func reload() {
        let reloadDisposeBag = DisposeBag()
        
        reloadBag.value = reloadDisposeBag

        let reload = API.default.request(.latest)
            .observeOn(ConcurrentDispatchQueueScheduler(globalConcurrentQueueQOS: .background))
            .flatMap { CurrencyFactory.instance.rx.parse(json: $0) }
            .observeOn(MainScheduler.instance).publish()
        
        reload
            .subscribe(
                onError: { [weak self] error in
                    self?.reloadBag.value = nil
                },
                onCompleted: { [weak self] error in
                    self?.reloadBag.value = nil
                }
            )
            .addDisposableTo(reloadDisposeBag)
        
        reload.connect().addDisposableTo(reloadDisposeBag)
    }
}

extension ViewController {
    fileprivate func setupSubscriptions() {
        
        // reload
        do {
            CurrencyNotification.checkReload.rx.post
                .map { _ in return }
                .filter { _ in
                    guard let updated = CurrencyFactory.instance.updatedTime else { return true }
                    return Date().timeIntervalSince1970 - updated > API.default.updateInterval
                }
                .debounce(0.1, scheduler: MainScheduler.instance)
                .bindNext(reload)
                .addDisposableTo(disposeBag)
            
            reloadButton.rx.tap
                .debounce(0.3, scheduler: MainScheduler.instance)
                .bindNext(reload)
                .addDisposableTo(disposeBag)
            
            Observable.from([rx.isLoading.map { !$0 }, reloadButton.rx.tap.map { false } ])
                .merge()
                .bindTo(reloadButton.rx.enabled)
                .addDisposableTo(disposeBag)
            
            reloadBag.asObservable()
                .map { $0 != nil }
                .bindTo(UIApplication.shared.rx.networkActivityIndicatorVisible)
                .addDisposableTo(disposeBag)
        }
        
        // rate date
        do {
            Observable.combineLatest(
                CurrencyFactory.instance.rx.rateDateString, rx.isLoading) { (string, isLoading) in
                    return isLoading ? "Refreshing..." : "Rates at \(string)"
                }
                .observeOn(MainScheduler.instance)
                .bindTo(rx.title)
                .addDisposableTo(disposeBag)
        }
        
        // API loaded
        do {
            let initial = CurrencyFactory.instance.rx.currencies.take(1).observeOn(MainScheduler.instance).publish()
            
            initial
                .map { [weak self] _ in self?.defaultUpperCurrency ?? Currency.null }
                .bindTo(upperCurrencyView.rx.currency)
                .addDisposableTo(disposeBag)
            
            initial
                .map { [weak self] _ in self?.defaultLowerCurrency ?? Currency.null }
                .bindTo(lowerCurrencyView.rx.currency)
                .addDisposableTo(disposeBag)
            
            initial.map { _ in return }.bindNext(lockNumber).addDisposableTo(disposeBag)

            initial
                .map { _ in Settings.instance.lowerNumber ?? 0 }
                .bindTo(lowerCurrencyView.rx.number)
                .addDisposableTo(disposeBag)

            initial.connect().addDisposableTo(disposeBag)
        }
        
        // API loaded
        do {
            let update = CurrencyFactory.instance.rx.currencies.skip(1).observeOn(MainScheduler.instance).publish()

            update
                .subscribe(onNext: { [weak self] _ in
                    guard let sself = self else { return }
                    let currency = sself.upperCurrencyView.currency
                    sself.upperCurrencyView.currency =
                        CurrencyFactory.instance.contains(currencyCode: currency.code) ?
                            currency : sself.defaultUpperCurrency
                })
                .addDisposableTo(disposeBag)
            
            update
                .subscribe(onNext: { [weak self] _ in
                    guard let sself = self else { return }
                    if CurrencyFactory.instance.contains(currencyCode: sself.lowerCurrencyView.currency.code) { return }
                    sself.lowerCurrencyView.currency = sself.defaultLowerCurrency
                })
                .addDisposableTo(disposeBag)

            update.connect().addDisposableTo(disposeBag)

        }
        
        // convert action
        do {
            let toLower = Observable.combineLatest(
                upperCurrencyView.rx.number,
                lowerCurrencyView.rx.currency
            ) { $0 }
                .filter { [weak self] _ in self?.checkLock() ?? false }
                .map { [weak upperCurrencyView] in
                    ($0, upperCurrencyView?.currency ?? Currency.null, $1)
                }
                .map(CurrencyFactory.instance.convert)
                .publish()
            
            toLower.map { _ in return }.bindNext(lockNumber).addDisposableTo(disposeBag)
            toLower.bindTo(lowerCurrencyView.rx.number).addDisposableTo(disposeBag)
            
            toLower.connect().addDisposableTo(disposeBag)
            
            
            let toUpper = Observable.combineLatest(
                lowerCurrencyView.rx.number,
                upperCurrencyView.rx.currency
            ) { $0 }
                .filter { [weak self] _ in self?.checkLock() ?? false}
                .map { [weak lowerCurrencyView] in
                    ($0, lowerCurrencyView?.currency ?? Currency.null, $1)
                }
                .map(CurrencyFactory.instance.convert)
                .publish()
            
            toUpper.map { _ in return }.bindNext(lockNumber).addDisposableTo(disposeBag)
            toUpper.bindTo(upperCurrencyView.rx.number).addDisposableTo(disposeBag)
            
            toUpper.connect().addDisposableTo(disposeBag)
        }
        
        // swap
        do {
            Observable.from([swapHButton.rx.tap, swapVButton.rx.tap])
                .merge().bindNext(swap).addDisposableTo(disposeBag)
        }
        
        // status
        do {
            upperCurrencyView.rx.currency.bindTo(Settings.instance.rx.upperCurrency).addDisposableTo(disposeBag)
            lowerCurrencyView.rx.currency.bindTo(Settings.instance.rx.lowerCurrency).addDisposableTo(disposeBag)
            lowerCurrencyView.rx.number.bindTo(Settings.instance.rx.lowerNumber).addDisposableTo(disposeBag)
        }
    }
}

extension ViewController {
    fileprivate var defaultUpperCurrency: Currency {
        return Settings.instance.upperCurrency ??
            CurrencyFactory.instance.currency(ofLocale: Locale.current) ??
            CurrencyFactory.instance.currency(ofCode: "USD") ??
            CurrencyFactory.instance.firstCurrency ??
            Currency.null
    }

    fileprivate var defaultLowerCurrency: Currency {
        return Settings.instance.lowerCurrency ??
            CurrencyFactory.instance.currency(ofCode: "USD") ??
            CurrencyFactory.instance.firstCurrency ??
            Currency.null
    }

    fileprivate func lockNumber() {
        numberUnlocked = false
    }
    
    fileprivate func checkLock() -> Bool {
        if numberUnlocked { return true }
        numberUnlocked = true
        return false
    }
    
    fileprivate func swap() {
        let upperCurrency = upperCurrencyView.currency
        let upperNumber = upperCurrencyView.number
        
        lockNumber()
        upperCurrencyView.currency = lowerCurrencyView.currency
        lockNumber()
        upperCurrencyView.number = lowerCurrencyView.number
        lockNumber()
        lowerCurrencyView.currency = upperCurrency
        lockNumber()
        lowerCurrencyView.number = upperNumber
    }
    
}

extension Reactive where Base : ViewController {
    
    var isLoading: Observable<Bool> {
        return base.reloadBag.asObservable().map { $0 != nil }
    }
    
}
