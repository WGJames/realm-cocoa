////////////////////////////////////////////////////////////////////////////
//
// Copyright 2014 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////

#import "RLMArray_Private.hpp"

#import "RLMObjectSchema_Private.hpp"
#import "RLMObjectStore.h"
#import "RLMObject_Private.hpp"
#import "RLMObservation.hpp"
#import "RLMProperty_Private.h"
#import "RLMQueryUtil.hpp"
#import "RLMRealm_Private.hpp"
#import "RLMSchema.h"
#import "RLMThreadSafeReference_Private.hpp"
#import "RLMUtil.hpp"

#import "list.hpp"
#import "results.hpp"

#import <realm/table_view.hpp>
#import <objc/runtime.h>

@interface RLMArraySubTableHandoverMetadata : NSObject
@property (nonatomic) NSString *parentClassName;
@property (nonatomic) NSString *key;
@end

@implementation RLMArraySubTableHandoverMetadata
@end

@interface RLMArraySubTable () <RLMThreadConfined_Private>
@end

//
// RLMArray implementation
//
@implementation RLMArraySubTable {
@public
    realm::TableRef _table;
    RLMRealm *_realm;
    RLMClassInfo *_objectInfo;
    RLMClassInfo *_ownerInfo;
    std::unique_ptr<RLMObservationInfo> _observationInfo;
}

- (RLMArraySubTable *)initWithTable:(realm::TableRef)table
                             realm:(__unsafe_unretained RLMRealm *const)realm
                        parentInfo:(RLMClassInfo *)parentInfo
                          property:(__unsafe_unretained RLMProperty *const)property {
    self = [self initWithObjectType:property.type optional:property.optional];
    if (self) {
        _realm = realm;
        _table = table;
        _objectInfo = &parentInfo->linkTargetType(property.index);
        _ownerInfo = parentInfo;
        _key = property.name;
    }
    return self;
}

- (RLMArraySubTable *)initWithParent:(__unsafe_unretained RLMObjectBase *const)parentObject
                            property:(__unsafe_unretained RLMProperty *const)property {
    return [self initWithTable:parentObject->_row.get_subtable(parentObject->_info->tableColumn(property))
                        realm:parentObject->_realm
                   parentInfo:parentObject->_info
                     property:property];
}

template<typename IndexSetFactory>
static void changeArray(__unsafe_unretained RLMArraySubTable *const,
                        NSKeyValueChange, dispatch_block_t f, IndexSetFactory&&) {
    f();
#if 0
    RLMObservationInfo *info = RLMGetObservationInfo(ar->_observationInfo.get(),
                                                     ar->_backingList.get_origin_row_index(),
                                                     *ar->_ownerInfo);
    if (info) {
        NSIndexSet *indexes = is();
        info->willChange(ar->_key, kind, indexes);
        try {
            f();
        }
        catch (...) {
            info->didChange(ar->_key, kind, indexes);
            throwError();
        }
        info->didChange(ar->_key, kind, indexes);
    }
    else {
        translateErrors([&] { f(); });
    }
#endif
}

static void changeArray(__unsafe_unretained RLMArraySubTable *const ar, NSKeyValueChange kind, NSUInteger index, dispatch_block_t f) {
    changeArray(ar, kind, f, [=] { return [NSIndexSet indexSetWithIndex:index]; });
}

static void changeArray(__unsafe_unretained RLMArraySubTable *const ar, NSKeyValueChange kind, NSRange range, dispatch_block_t f) {
    changeArray(ar, kind, f, [=] { return [NSIndexSet indexSetWithIndexesInRange:range]; });
}

static void changeArray(__unsafe_unretained RLMArraySubTable *const ar, NSKeyValueChange kind, NSIndexSet *is, dispatch_block_t f) {
    changeArray(ar, kind, f, [=] { return is; });
}

//
// public method implementations
//
- (RLMRealm *)realm {
    return _realm;
}

- (NSUInteger)count {
    return _table->size();
}

- (BOOL)isInvalidated {
    return !_table->is_attached();
}

- (RLMClassInfo *)objectInfo {
    return _objectInfo;
}

- (BOOL)isEqual:(id)object {
    if (auto array = RLMDynamicCast<RLMArraySubTable>(object)) {
        return array->_table == _table;
    }
    return NO;
}

- (NSUInteger)hash {
    return std::hash<void *>()(_table.get());
}

static void set(realm::Table& table, size_t ndx, id value) {
    switch (table.get_column_type(0)) {
        case realm::type_Int: table.set_int(0, ndx, [value longLongValue]);
        default: REALM_UNREACHABLE();
    }
}

static id get(realm::Table& table, size_t ndx) {
    switch (table.get_column_type(0)) {
        case realm::type_Int: @(table.get_int(0, ndx));
        default: REALM_UNREACHABLE();
    }
}


- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state
                                  objects:(__unused __unsafe_unretained id [])buffer
                                    count:(NSUInteger)len {
    __autoreleasing RLMFastEnumerator *enumerator;
    if (state->state == 0) {
        enumerator = [[RLMFastEnumerator alloc] initWithCollection:self objectSchema:*_objectInfo];
        state->extra[0] = (long)enumerator;
        state->extra[1] = self.count;
    }
    else {
        enumerator = (__bridge id)(void *)state->extra[0];
    }

    return [enumerator countByEnumeratingWithState:state count:len];
}

- (id)objectAtIndex:(NSUInteger)index {
    return get(*_table, index);
}

static void RLMInsertObject(RLMArraySubTable *ar, id object, NSUInteger index) {
    if (index == NSUIntegerMax) {
        index = ar->_table->size();
    }

    changeArray(ar, NSKeyValueChangeInsertion, index, ^{
        ar->_table->insert_empty_row(index);
        set(*ar->_table, index, object);
    });
}

- (void)addObject:(id)object {
    RLMInsertObject(self, object, NSUIntegerMax);
}

- (void)insertObject:(id)object atIndex:(NSUInteger)index {
    RLMInsertObject(self, object, index);
}

- (void)insertObjects:(id<NSFastEnumeration>)objects atIndexes:(NSIndexSet *)indexes {
    changeArray(self, NSKeyValueChangeInsertion, indexes, ^{
        NSUInteger index = [indexes firstIndex];
        for (id obj in objects) {
            _table->insert_empty_row(index);
            set(*_table, index, obj);
            index = [indexes indexGreaterThanIndex:index];
        }
    });
}


- (void)removeObjectAtIndex:(NSUInteger)index {
    changeArray(self, NSKeyValueChangeRemoval, index, ^{
        _table->remove(index);
    });
}

- (void)removeObjectsAtIndexes:(NSIndexSet *)indexes {
    changeArray(self, NSKeyValueChangeRemoval, indexes, ^{
        [indexes enumerateIndexesWithOptions:NSEnumerationReverse usingBlock:^(NSUInteger idx, BOOL *) {
            _table->remove(idx);
        }];
    });
}

- (void)addObjectsFromArray:(NSArray *)array {
    changeArray(self, NSKeyValueChangeInsertion, NSMakeRange(self.count, array.count), ^{
        size_t row = _table->add_empty_row(array.count);
        for (id obj in array) {
            set(*_table, row++, obj);
        }
    });
}

- (void)removeAllObjects {
    changeArray(self, NSKeyValueChangeRemoval, NSMakeRange(0, self.count), ^{
        _table->clear();
    });
}

- (void)replaceObjectAtIndex:(NSUInteger)index withObject:(id)object {
    changeArray(self, NSKeyValueChangeReplacement, index, ^{
        set(*_table, index, object);
    });
}

- (void)exchangeObjectAtIndex:(NSUInteger)index1 withObjectAtIndex:(NSUInteger)index2 {
    changeArray(self, NSKeyValueChangeReplacement, ^{
        _table->swap_rows(index1, index2);
    }, [=] {
        NSMutableIndexSet *set = [[NSMutableIndexSet alloc] initWithIndex:index1];
        [set addIndex:index2];
        return set;
    });
}

- (NSUInteger)indexOfObject:(RLMObject *)object {
    if (object.invalidated) {
        @throw RLMException(@"Object has been deleted or invalidated");
    }

    // check that object types align
    if (![_objectClassName isEqualToString:object->_objectSchema.className]) {
        @throw RLMException(@"Object of type (%@) does not match RLMArray type (%@)",
                            object->_objectSchema.className, _objectClassName);
    }

    // return RLMConvertNotFound(_table->find_first(0, 0));
    return NSNotFound;
}

- (id)valueForKeyPath:(NSString *)keyPath {
    return [super valueForKeyPath:keyPath];
}

- (id)valueForKey:(NSString *)key {
    return [super valueForKey:key];
}

- (void)setValue:(__unused id)value forKey:(__unused NSString *)key {
    // RLMCollectionSetValueForKey(self, key, value);
}

#if 0
- (RLMResults *)sortedResultsUsingDescriptors:(NSArray<RLMSortDescriptor *> *)properties {
    if (properties.count == 0) {
        auto results = translateErrors([&] { return _backingList.filter({}); });
        return [RLMResults resultsWithObjectInfo:*_objectInfo results:std::move(results)];
    }

    auto order = RLMSortDescriptorFromDescriptors(*_objectInfo, properties);
    auto results = translateErrors([&] { return _backingList.sort(std::move(order)); });
    return [RLMResults resultsWithObjectInfo:*_objectInfo results:std::move(results)];
}

- (RLMResults *)objectsWithPredicate:(NSPredicate *)predicate {
    auto query = RLMPredicateToQuery(predicate, _objectInfo->rlmObjectSchema, _realm.schema, _realm.group);
    auto results = translateErrors([&] { return _backingList.filter(std::move(query)); });
    return [RLMResults resultsWithObjectInfo:*_objectInfo results:std::move(results)];
}

- (NSUInteger)indexOfObjectWithPredicate:(NSPredicate *)predicate {
    auto query = translateErrors([&] { return _backingList.get_query(); });
    query.and_query(RLMPredicateToQuery(predicate, _objectInfo->rlmObjectSchema, _realm.schema, _realm.group));
#if REALM_VER_MAJOR >= 2
    auto indexInTable = query.find();
    if (indexInTable == realm::not_found) {
        return NSNotFound;
    }
    auto row = query.get_table()->get(indexInTable);
    return _backingList.find(row);
#else
    return RLMConvertNotFound(query.find());
#endif
}

- (NSArray *)objectsAtIndexes:(__unused NSIndexSet *)indexes {
    // FIXME: this is called by KVO when array changes are made. It's not clear
    // why, and returning nil seems to work fine.
    return nil;
}

- (void)addObserver:(id)observer
         forKeyPath:(NSString *)keyPath
            options:(NSKeyValueObservingOptions)options
            context:(void *)context {
    RLMEnsureArrayObservationInfo(_observationInfo, keyPath, self, self);
    [super addObserver:observer forKeyPath:keyPath options:options context:context];
}

- (NSUInteger)indexInSource:(NSUInteger)index {
    return _backingList.get_unchecked(index);
}

- (realm::TableView)tableView {
    return translateErrors([&] { return _backingList.get_query(); }).find_all();
}

// The compiler complains about the method's argument type not matching due to
// it not having the generic type attached, but it doesn't seem to be possible
// to actually include the generic type
// http://www.openradar.me/radar?id=6135653276319744
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wmismatched-parameter-types"
- (RLMNotificationToken *)addNotificationBlock:(void (^)(RLMArray *, RLMCollectionChange *, NSError *))block {
    [_realm verifyNotificationsAreSupported];
    return RLMAddNotificationBlock(self, _backingList, block);
}
#pragma clang diagnostic pop

#pragma mark - Thread Confined Protocol Conformance

- (std::unique_ptr<realm::ThreadSafeReferenceBase>)makeThreadSafeReference {
    realm::ThreadSafeReference<realm::List> list_reference = _realm->_realm->obtain_thread_safe_reference(_backingList);
    return std::make_unique<realm::ThreadSafeReference<realm::List>>(std::move(list_reference));
}

- (RLMArraySubTableHandoverMetadata *)objectiveCMetadata {
    RLMArraySubTableHandoverMetadata *metadata = [[RLMArraySubTableHandoverMetadata alloc] init];
    metadata.parentClassName = _ownerInfo->rlmObjectSchema.className;
    metadata.key = _key;
    return metadata;
}

+ (instancetype)objectWithThreadSafeReference:(std::unique_ptr<realm::ThreadSafeReferenceBase>)reference
                                     metadata:(RLMArraySubTableHandoverMetadata *)metadata
                                        realm:(RLMRealm *)realm {
    REALM_ASSERT_DEBUG(dynamic_cast<realm::ThreadSafeReference<realm::List> *>(reference.get()));
    auto list_reference = static_cast<realm::ThreadSafeReference<realm::List> *>(reference.get());

    realm::List list = realm->_realm->resolve_thread_safe_reference(std::move(*list_reference));
    if (!list.is_valid()) {
        return nil;
    }
    RLMClassInfo *parentInfo = &realm->_info[metadata.parentClassName];
    return [[RLMArraySubTable alloc] initWithList:std::move(list)
                                            realm:realm
                                       parentInfo:parentInfo
                                         property:parentInfo->rlmObjectSchema[metadata.key]];
}
#endif

@end
