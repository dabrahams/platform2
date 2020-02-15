//******************************************************************************
// Copyright 2020 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
import Foundation

//==============================================================================
/// TensorStorageProtocol
public protocol TensorStorageProtocol
{
    associatedtype Element
    
    /// the number of stored elements
    var count: Int { get }
    /// a name used in diagnostic messages
    var name: String { get }
    /// the id returned from `createBuffer`
    var deviceStorage: BufferId { get }
    
    /// read(buffer:on:
    /// - Parameter id: id of the buffer
    /// - Parameter using: specifies the device/queue for synchronization.
    /// A value of `nil` blocks the caller until synchronization is complete.
    /// - Returns: a buffer pointer to the stored elements
    func read(_ id: BufferId, using deviceQueue: (device: Int, queue: Int))
        -> UnsafeBufferPointer<Element>
    /// readWrite(buffer:on:
    /// - Parameter id: id of the buffer
    /// - Parameter using: specifies the device queue for synchronization.
    /// A value of `nil` blocks the caller until synchronization is complete.
    /// - Parameter overwrite: `true` if the caller guarantees all
    /// buffer elements will be overwritten
    /// - Returns: a mutable buffer pointer to the stored elements
    func readWrite(_ id: BufferId, using deviceQueue: (device: Int, queue: Int),
                   overwrite: Bool)
        -> UnsafeMutableBufferPointer<Element>
}

//==============================================================================
/// TensorStorageProtocol
public extension TensorStorageProtocol
{
    func read(_ id: BufferId, using deviceQueue: (device: Int, queue: Int))
        -> UnsafeBufferPointer<Element>
    {
        Current.service.read(deviceStorage, using: deviceQueue)
            .bindMemory(to: Element.self)
    }
    
    func readWrite(_ id: BufferId, using deviceQueue: (device: Int, queue: Int),
                   overwrite: Bool)
        -> UnsafeMutableBufferPointer<Element>
    {
        Current.service.readWrite(deviceStorage, using: deviceQueue,
                                  overwrite: overwrite)
            .bindMemory(to: Element.self)
    }
}

//==============================================================================
/// TensorStorage
/// reference counted access to a host memory buffer managed by the platform
public final class TensorStorage<Element>:
    TensorStorageProtocol, ObjectTracking, Logging
{
    public let count: Int
    public let name: String
    public let deviceStorage: BufferId
    public let trackingId: Int

    @usableFromInline
    init(_ storageId: BufferId, _ name: String, _ count: Int) {
        self.count = count
        self.name = name
        self.deviceStorage = storageId
        self.trackingId = ObjectTracker.global.nextId
        #if DEBUG
        ObjectTracker.global.register(
            self, namePath: logNamePath, supplementalInfo:
            "\(String(describing: Element.self))[\(count)]")
        #endif
    }
    
    //--------------------------------------------------------------------------
    // creates a buffer of the specified size
    @inlinable
    public convenience init(count: Int, name: String)
    {
        let bufferId = Current.service
            .createBuffer(byteCount: MemoryLayout<Element>.size * count)
        self.init(bufferId, name, count)
    }

    //--------------------------------------------------------------------------
    // creates a buffer that is a read only reference to an applicaiton buffer
    @inlinable
    public convenience
    init(referenceTo buffer: UnsafeBufferPointer<Element>, name: String)
    {
        let bufferId = Current.service
            .createReference(to: UnsafeRawBufferPointer(buffer))
        self.init(bufferId, name, buffer.count)
    }

    //--------------------------------------------------------------------------
    // creates a buffer that is a read write reference to an applicaiton buffer
    @inlinable
    public convenience
    init(referenceTo buffer: UnsafeMutableBufferPointer<Element>, name: String)
    {
        let bufferId = Current.service
            .createMutableReference(to: UnsafeMutableRawBufferPointer(buffer))
        self.init(bufferId, name, buffer.count)
    }

    //--------------------------------------------------------------------------
    // release the storage buffer when the reference count reaches zero
    deinit {
        Current.service.release(deviceStorage)
        ObjectTracker.global.remove(trackingId: trackingId)
    }
}

//==============================================================================
// Codable
// useful discussion on techniques
// https://www.raywenderlich.com/3418439-encoding-and-decoding-in-swift
extension TensorStorage: Codable where Element: Codable {
    public enum CodingKeys: String, CodingKey { case name, data }
    
    /// encodes the contents of the array
    @inlinable
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        var dataContainer = container.nestedUnkeyedContainer(forKey: .data)
        let buffer = read(deviceStorage, using: cpuDevice)
        try buffer.forEach {
            try dataContainer.encode($0)
        }
    }
    
    @inlinable
    public convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        var dataContainer = try container.nestedUnkeyedContainer(forKey: .data)
        if let count = dataContainer.count {
            self.init(count: count, name: name)
            let elements = readWrite(deviceStorage, using: cpuDevice,
                                     overwrite: true)
            for i in 0..<count {
                elements[i] = try dataContainer.decode(Element.self)
            }
        } else {
            self.init(count: 0, name: name)
        }
    }
}
