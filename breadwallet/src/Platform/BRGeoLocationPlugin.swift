//
//  BRGeoLocationPlugin.swift
//  BreadWallet
//
//  Created by Samuel Sutch on 2/8/16.
//  Copyright (c) 2016 breadwallet LLC
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

import Foundation
import CoreLocation


@available(iOS 8.0, *)
class BRGeoLocationDelegate: NSObject, CLLocationManagerDelegate {
    var manager: CLLocationManager? = nil
    var response: BRHTTPResponse
    var remove: (() -> Void)? = nil
    var one = false
    var nResponses = 0
    // on versions ios < 9.0 we don't have the energy-efficient/convenient requestLocation() method
    // so after fetching a good location we should terminate location updates
    var shouldCancelUpdatingAfterReceivingLocation = false
    
    init(response: BRHTTPResponse) {
        self.response = response
        super.init()
        DispatchQueue.main.sync { () -> Void in
            self.manager = CLLocationManager()
            self.manager?.delegate = self
        }
    }
    
    func getOne() {
        one = true
        DispatchQueue.main.sync { () -> Void in
            self.manager?.desiredAccuracy = kCLLocationAccuracyHundredMeters
            self.manager?.requestLocation()
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if one && nResponses > 0 { return }
        var j = [String: Any]()
        let l = locations.last!
        if (shouldCancelUpdatingAfterReceivingLocation
            && !(l.horizontalAccuracy <= kCLLocationAccuracyHundredMeters
                 && l.verticalAccuracy <= kCLLocationAccuracyHundredMeters)) {
            // return if location is not the requested accuracy of 100m
            return
        }
        nResponses += 1
        if (shouldCancelUpdatingAfterReceivingLocation) {
            self.manager?.stopUpdatingLocation()
        }
        j["timestamp"] = l.timestamp.description as AnyObject?
        j["coordinate"] = ["latitude": l.coordinate.latitude, "longitude": l.coordinate.longitude]
        j["altitude"] = l.altitude as AnyObject?
        j["horizontal_accuracy"] = l.horizontalAccuracy as AnyObject?
        j["description"] = l.description as AnyObject?
        response.request.queue.async {
            self.response.provide(200, json: j)
            self.remove?()
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        var j = [String: AnyObject]()
        j["error"] = error.localizedDescription as AnyObject?
        response.request.queue.async {
            self.response.provide(500, json: j)
            self.remove?()
        }
    }
}

@available(iOS 8.0, *)
open class BRGeoLocationPlugin: NSObject, BRHTTPRouterPlugin, CLLocationManagerDelegate, BRWebSocketClient {
    lazy var manager = CLLocationManager()
    var outstanding = [BRGeoLocationDelegate]()
    var sockets = [String: BRWebSocket]()
    
    override init() {
        super.init()
        self.manager.delegate = self
    }
    
    open func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        print("new authorization status: \(status)")
    }
    
    open func hook(_ router: BRHTTPRouter) {
        // GET /_permissions/geo
        //
        // Call this method to retrieve the current permission status for geolocation.
        // The returned JSON dictionary contains the following keys:
        //
        // "status" = "denied" | "restricted | "undetermined" | "inuse" | "always"
        // "user_queried" = true | false
        // "location_enabled" = true | false
        //
        // The status correspond to those found in the apple CLLocation documentation: http://apple.co/1O0lHFv
        //
        // "user_queried" indicates whether or not the user has already been asked for geolocation
        // "location_enabled" indicates whether or not the user has geo location enabled on their phone
        router.get("/_permissions/geo") { (request, match) -> BRHTTPResponse in
            let userDefaults = UserDefaults.standard
            let authzStatus = CLLocationManager.authorizationStatus()
            var retJson = [String: Any]()
            switch authzStatus {
            case .denied:
                retJson["status"] = "denied"
            case .restricted:
                retJson["status"] = "restricted"
            case .notDetermined:
                retJson["status"] = "undetermined"
            case .authorizedWhenInUse:
                retJson["status"] = "inuse"
            case .authorizedAlways:
                retJson["status"] = "always"
            }
            retJson["user_queried"] = userDefaults.bool(forKey: "geo_permission_was_queried")
            retJson["location_enabled"] = CLLocationManager.locationServicesEnabled()
            return try BRHTTPResponse(request: request, code: 200, json: retJson as AnyObject)
        }
        
        // POST /_permissions/geo
        //
        // Call this method to request the geo permission from the user.
        // The request body should be a JSON dictionary containing a single key, "style"
        // the value of which should be either "inuse" or "always" - these correspond to the
        // two ways the user can authorize geo access to the app. "inuse" will request
        // geo availability to the app when the app is foregrounded, and "always" will request
        // full time geo availability to the app
        router.post("/_permissions/geo") { (request, match) -> BRHTTPResponse in
            if let j = request.json(), let dict = j as? NSDictionary, let style = dict["style"] as? String {
                switch style {
                case "inuse": self.manager.requestWhenInUseAuthorization()
                case "always": self.manager.requestAlwaysAuthorization()
                default: return BRHTTPResponse(request: request, code: 400)
                }
                UserDefaults.standard.set(true, forKey: "geo_permission_was_queried")
                return BRHTTPResponse(request: request, code: 204)
            }
            return BRHTTPResponse(request: request, code: 400)
        }
        
        // GET /_geo
        //
        // Calling this method will query CoreLocation for a location object. The returned value may not be returned
        // very quick (sometimes getting a geo lock takes some time) so be sure to display to the user some status
        // while waiting for a response.
        //
        // Response Object:
        //
        // "coordinates" = { "latitude": double, "longitude": double }
        // "altitude" = double
        // "description" = "a string representation of this object"
        // "timestamp" = "ISO-8601 timestamp of when this location was generated"
        // "horizontal_accuracy" = double
        router.get("/_geo") { (request, match) -> BRHTTPResponse in
            if let authzErr = self.getAuthorizationError() {
                return try BRHTTPResponse(request: request, code: 400, json: authzErr)
            }
            let resp = BRHTTPResponse(async: request)
            let del = BRGeoLocationDelegate(response: resp)
            del.remove = {
                objc_sync_enter(self)
                if let idx = self.outstanding.index(where: { (d) -> Bool in return d == del }) {
                    self.outstanding.remove(at: idx)
                }
                objc_sync_exit(self)
            }
            objc_sync_enter(self)
            self.outstanding.append(del)
            objc_sync_exit(self)
            
            print("outstanding delegates: \(self.outstanding)")
            
            // get location only once
            del.getOne()
            
            return resp
        }
        
        // GET /_geosocket
        //
        // This opens up a websocket to the location manager. It will return a new location every so often (but with no
        // predetermined interval) with the same exact structure that is sent via the GET /_geo call.
        // 
        // It will start the location manager when there is at least one client connected and stop the location manager
        // when the last client disconnects.
        router.websocket("/_geosocket", client: self)
    }
    
    func getAuthorizationError() -> [String: Any]? {
        var retJson = [String: Any]()
        if !CLLocationManager.locationServicesEnabled() {
            retJson["error"] = NSLocalizedString("Location services are disabled", comment: "")
            return retJson
        }
        let authzStatus = CLLocationManager.authorizationStatus()
        if authzStatus != .authorizedWhenInUse && authzStatus != .authorizedAlways {
            retJson["error"] = NSLocalizedString("Location services are not authorized", comment: "")
            return retJson
        }
        return nil
    }
    
    var lastLocation: [String: Any]?
    var isUpdatingSockets = false
    
    // location manager for continuous websocket clients
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        var j = [String: Any]()
        let l = locations.last!
        j["timestamp"] = l.timestamp.description as AnyObject?
        j["coordinate"] = ["latitude": l.coordinate.latitude, "longitude": l.coordinate.longitude]
        j["altitude"] = l.altitude as AnyObject?
        j["horizontal_accuracy"] = l.horizontalAccuracy as AnyObject?
        j["description"] = l.description as AnyObject?
        lastLocation = j
        sendToAllSockets(data: j)
    }
    
    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        var j = [String: Any]()
        j["error"] = error.localizedDescription as AnyObject?
        sendToAllSockets(data: j)
    }
    
    func sendTo(socket: BRWebSocket, data: [String: Any]) {
        do {
            let j = try JSONSerialization.data(withJSONObject: data, options: [])
            if let s = String(data: j, encoding: .utf8) {
                socket.request.queue.async {
                    socket.send(s)
                }
            }
        } catch let e {
            print("LOCATION SOCKET FAILED ENCODE JSON: \(e)")
        }
    }
    
    func sendToAllSockets(data: [String: Any]) {
        for (_, s) in sockets {
            sendTo(socket: s, data: data)
        }
    }
    
    public func socketDidConnect(_ socket: BRWebSocket) {
        print("LOCATION SOCKET CONNECT \(socket.id)")
        sockets[socket.id] = socket
        // on first socket connect to the manager
        if !isUpdatingSockets {
            // if not authorized yet send an error
            if let authzErr = getAuthorizationError() {
                sendTo(socket: socket, data: authzErr)
                return
            }
            // begin updating location
            isUpdatingSockets = true
            DispatchQueue.main.sync { () -> Void in
                self.manager.delegate = self
                self.manager.startUpdatingLocation()
            }
        }
        if let loc = lastLocation {
            sendTo(socket: socket, data: loc)
        }
    }
    
    public func socketDidDisconnect(_ socket: BRWebSocket) {
        print("LOCATION SOCKET DISCONNECT \(socket.id)")
        sockets.removeValue(forKey: socket.id)
        // on last socket disconnect stop updating location
        if sockets.count == 0 {
            isUpdatingSockets = false
            lastLocation = nil
            self.manager.stopUpdatingLocation()
        }
    }
    
    public func socket(_ socket: BRWebSocket, didReceiveText text: String) {
        print("LOCATION SOCKET RECV \(text)")
        // this is unused here but just in case just echo received text back
        socket.send(text)
    }
    
    public func socket(_ socket: BRWebSocket, didReceiveData data: Data) {
        // nothing to do here
    }
}