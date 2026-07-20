package com.geowake.app;

import androidx.test.platform.app.InstrumentationRegistry;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.junit.runners.Parameterized;
import org.junit.runners.Parameterized.Parameters;
import pl.leancode.patrol.PatrolJUnitRunner;

// Patrol 4.7.1 JUnit entry point (LeanCode). This is the EXACT template shipped
// with patrol 4.7.1's example app, adapted to GeoWake:
//   - This androidTest source lives under the RUNTIME applicationId package
//     (com.geowake.app), which is what patrol's package_name points at.
//   - MainActivity is declared under the SOURCE namespace
//     (com.example.geowake2.MainActivity), so it must be imported explicitly —
//     it is not in this file's package.
//
// The @Parameterized runner asks PatrolJUnitRunner to enumerate the Dart tests
// (listDartTests) after standing up the native automation server
// (setUp + waitForPatrolAppService), then runs each one as its own parameterized
// JUnit case (runDartTest).
import com.example.geowake2.MainActivity;

@RunWith(Parameterized.class)
public class MainActivityTest {
    @Parameters(name = "{0}")
    public static Object[] testCases() {
        PatrolJUnitRunner instrumentation = (PatrolJUnitRunner) InstrumentationRegistry.getInstrumentation();
        instrumentation.setUp(MainActivity.class);
        instrumentation.waitForPatrolAppService();
        return instrumentation.listDartTests();
    }

    public MainActivityTest(String dartTestName) {
        this.dartTestName = dartTestName;
    }

    private final String dartTestName;

    @Test
    public void runDartTest() {
        PatrolJUnitRunner instrumentation = (PatrolJUnitRunner) InstrumentationRegistry.getInstrumentation();
        instrumentation.runDartTest(dartTestName);
    }
}
