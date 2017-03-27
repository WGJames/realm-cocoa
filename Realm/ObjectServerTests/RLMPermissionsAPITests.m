////////////////////////////////////////////////////////////////////////////
//
// Copyright 2017 Realm Inc.
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

#import <XCTest/XCTest.h>

#import "RLMSyncTestCase.h"

#import "RLMTestUtils.h"

#define WORKAROUND_PAUSE() [self wait:1]

@interface RLMPermissionsAPITests : RLMSyncTestCase

@property (nonatomic, strong) RLMSyncUser *userA;
@property (nonatomic, strong) RLMSyncUser *userB;

@end

@implementation RLMPermissionsAPITests

- (void)setUp {
    [super setUp];
    NSString *accountNameBase = [[NSUUID UUID] UUIDString];
    NSString *userNameA = [accountNameBase stringByAppendingString:@"_A"];
    self.userA = [self logInUserForCredentials:[RLMSyncTestCase basicCredentialsWithName:userNameA register:YES]
                                        server:[RLMSyncTestCase authServerURL]];

    NSString *userNameB = [accountNameBase stringByAppendingString:@"_B"];
    self.userB = [self logInUserForCredentials:[RLMSyncTestCase basicCredentialsWithName:userNameB register:YES]
                                        server:[RLMSyncTestCase authServerURL]];
}

- (void)tearDown {
    [self.userA logOut];
    [self.userB logOut];
    [super tearDown];
}

- (void)wait:(NSInteger)seconds {
    XCTestExpectation *ex = [self expectationWithDescription:@"Waiting..."];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [ex fulfill];
    });
    [self waitForExpectationsWithTimeout:(seconds + 5) handler:nil];
}

/// Setting a permission should work, and then that permission should be able to be retrieved.
- (void)testSettingPermission {
    // First, there should be no permissions.
    XCTestExpectation *ex = [self expectationWithDescription:@"No permissions for newly created user."];
    [self.userA retrievePermissions:^(RLMSyncPermissionResults *results, NSError *error) {
        XCTAssertNil(error);
        XCTAssertNotNil(results);
        XCTAssertEqual(results.count, 0);
        [ex fulfill];
    }];
    [self waitForExpectationsWithTimeout:2.0 handler:nil];

    // Open a Realm for user A.
    NSURL *url = REALM_URL();
    [self openRealmForURL:url user:self.userA];

    // Give user B read permissions to that Realm.
    RLMSyncPermissionValue *p = [[RLMSyncPermissionValue alloc] initWithRealmPath:[url path]
                                                                           userID:self.userB.identity
                                                                      accessLevel:RLMSyncAccessLevelRead];

    // Set the permission.
    XCTestExpectation *ex2 = [self expectationWithDescription:@"Setting a permission should work."];
    [self.userA applyPermission:p callback:^(NSError *error) {
        XCTAssertNil(error);
        [ex2 fulfill];
    }];
    [self waitForExpectationsWithTimeout:2.0 handler:nil];

    // Now retrieve the permissions again and make sure the new permission is properly set.
    XCTestExpectation *ex3 = [self expectationWithDescription:@"One permission after setting the permission."];
    [self.userA retrievePermissions:^(RLMSyncPermissionResults *results, NSError *error) {
        WORKAROUND_PAUSE();

        XCTAssertNil(error);
        XCTAssertNotNil(results);
        XCTAssertEqual(results.count, 1);
        RLMSyncPermissionValue *p = [results permissionAtIndex:0];
        XCTAssertEqualObjects(p.userID, self.userB.identity);
        XCTAssertEqual(p.accessLevel, RLMSyncAccessLevelRead);
        XCTAssertEqualObjects(p.path, [url path]);
        [ex3 fulfill];
    }];
    [self waitForExpectationsWithTimeout:2.0 handler:nil];
}

/// Deleting a permission should work.
- (void)testDeletingPermission {
    // Open a Realm for user A.
    NSURL *url = REALM_URL();
    [self openRealmForURL:url user:self.userA];

    // Give user B read permissions to that Realm.
    RLMSyncPermissionValue *p = [[RLMSyncPermissionValue alloc] initWithRealmPath:[url path]
                                                                           userID:self.userB.identity
                                                                      accessLevel:RLMSyncAccessLevelRead];

    // Set the permission.
    XCTestExpectation *ex = [self expectationWithDescription:@"Setting a permission should work."];
    [self.userA applyPermission:p callback:^(NSError *error) {
        XCTAssertNil(error);
        [ex fulfill];
    }];
    [self waitForExpectationsWithTimeout:2.0 handler:nil];

    // Now retrieve the permissions again and make sure the new permission is properly set.
    XCTestExpectation *ex2 = [self expectationWithDescription:@"One permission after setting the permission."];
    [self.userA retrievePermissions:^(RLMSyncPermissionResults *results, NSError *error) {
        WORKAROUND_PAUSE();
        XCTAssertNil(error);
        XCTAssertNotNil(results);
        XCTAssertEqual(results.count, 1);
        [ex2 fulfill];
    }];
    [self waitForExpectationsWithTimeout:2.0 handler:nil];

    // Delete the permission.
    XCTestExpectation *ex3 = [self expectationWithDescription:@"Deleting a permission should work."];
    [self.userA revokePermission:p callback:^(NSError *error) {
        XCTAssertNil(error);
        [ex3 fulfill];
    }];
    [self waitForExpectationsWithTimeout:2.0 handler:nil];

    // Make sure the permission deletion is properly reflected.
    XCTestExpectation *ex4 = [self expectationWithDescription:@"One permission after setting the permission."];
    [self.userA retrievePermissions:^(RLMSyncPermissionResults *results, NSError *error) {
        WORKAROUND_PAUSE();
        XCTAssertNil(error);
        XCTAssertNotNil(results);
        XCTAssertEqual(results.count, 0);
        [ex4 fulfill];
    }];
    [self waitForExpectationsWithTimeout:2.0 handler:nil];
}


/// Observing permission changes should work.
- (void)testObservingPermission {
    // Get a reference to the permission results.
    XCTestExpectation *ex = [self expectationWithDescription:@"Get permission results."];
    __block RLMSyncPermissionResults *results = nil;
    [self.userA retrievePermissions:^(RLMSyncPermissionResults *r, NSError *error) {
        XCTAssertNil(error);
        results = r;
        [ex fulfill];
    }];
    [self waitForExpectationsWithTimeout:2.0 handler:nil];
    XCTAssertNotNil(results);

    // Open a Realm for user A.
    NSURL *url = REALM_URL();
    [self openRealmForURL:url user:self.userA];

    // Register notifications.
    __block BOOL resultsNoLongerEmpty = NO;
    RLMSyncPermissionResultsToken *token = [results addNotificationBlock:^(NSError *error) {
        XCTAssertNil(error);
        if ([results count] > 0) {
            resultsNoLongerEmpty = YES;
        }
    }];

    // Give user B read permissions to that Realm.
    RLMSyncPermissionValue *p = [[RLMSyncPermissionValue alloc] initWithRealmPath:[url path]
                                                                           userID:self.userB.identity
                                                                      accessLevel:RLMSyncAccessLevelRead];

    // Set the permission.
    XCTestExpectation *ex2 = [self expectationWithDescription:@"Setting a permission should work."];
    [self.userA applyPermission:p callback:^(NSError *error) {
        XCTAssertNil(error);
        [ex2 fulfill];
    }];
    [self waitForExpectationsWithTimeout:2.0 handler:nil];

    // Now wait for the block to fire.
    if (!resultsNoLongerEmpty) {
        XCTestExpectation *ex3 = [self expectationWithDescription:@"Results block should provide updates."];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [ex3 fulfill];
        });
        [self waitForExpectationsWithTimeout:2.0 handler:nil];
    }
    [token stop];
}

@end
