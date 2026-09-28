import bindbc.box3d;
import bindbc.loader.sharedlib : LoadMsg;
import loader = bindbc.loader.sharedlib;
import std.stdio : stderr, writeln;
import std.string : fromStringz, toStringz;

void main(string[] args)
{
	LoadMsg loadResult;
	if (args.length > 1)
		loadResult = loadBox3D(args[1].toStringz);
	else
		loadResult = loadBox3D();

	if (loadResult != LoadMsg.success)
	{
		stderr.writeln("Could not load Box3D (loader status: ", loadResult, ").");
		foreach (error; loader.errors())
			stderr.writeln(fromStringz(error.error), ": ", fromStringz(error.message));
		stderr.writeln("Pass the Box3D shared-library path or add it to the OS loader search path.");
		return;
	}

	auto versionInfo = b3GetVersion();
	writeln("Box3D ", versionInfo.major, ".", versionInfo.minor, ".", versionInfo.revision);
	runStaticBodySimulation();
	runKinematicVelocityExample();
	runGravityCollisionExample();
	runStressTestSimulation();
	runRaylibVisualSample();
	unloadBox3D();
}

void runStaticBodySimulation()
{
	auto worldDefinition = b3DefaultWorldDef();
	auto world = b3CreateWorld(&worldDefinition);
	auto shapeDefinition = b3DefaultShapeDef();

	auto boxBodyDefinition = b3DefaultBodyDef();
	boxBodyDefinition.position.y = 1.0f;
	auto boxBody = b3CreateBody(world, &boxBodyDefinition);
	auto box = b3MakeBoxHull(1.0f, 1.0f, 1.0f);
	b3CreateHullShape(boxBody, &shapeDefinition, &box.base);

	auto sphereBodyDefinition = b3DefaultBodyDef();
	sphereBodyDefinition.position.y = 3.0f;
	auto sphereBody = b3CreateBody(world, &sphereBodyDefinition);
	auto sphereDefinition = b3Sphere(b3Vec3(0.0f, 0.0f, 0.0f), 0.5f);
	b3CreateSphereShape(sphereBody, &shapeDefinition, &sphereDefinition);

	foreach (_; 0 .. 120)
		b3World_Step(world, 1.0f / 60.0f, 4);

	auto counters = b3World_GetCounters(world);
	writeln("Static-body simulation: ", counters.bodyCount, " bodies after 2 seconds.");
	b3DestroyWorld(world);
}

void runKinematicVelocityExample()
{
	auto worldDefinition = b3DefaultWorldDef();
	auto world = b3CreateWorld(&worldDefinition);
	auto bodyDefinition = b3DefaultBodyDef();
	bodyDefinition.type = b3_kinematicBody;
	bodyDefinition.position.y = 2.0f;
	auto body = b3CreateBody(world, &bodyDefinition);
	auto shapeDefinition = b3DefaultShapeDef();
	auto sphereDefinition = b3Sphere(b3Vec3(0.0f, 0.0f, 0.0f), 0.5f);
	b3CreateSphereShape(body, &shapeDefinition, &sphereDefinition);
	b3Body_SetLinearVelocity(body, b3Vec3(1.0f, 0.0f, 0.0f));
	auto requestedVelocity = b3Body_GetLinearVelocity(body);
	writeln("Requested kinematic velocity: (", requestedVelocity.x, ", ", requestedVelocity.y, ", ",
		requestedVelocity.z, ")");

	foreach (_; 0 .. 60)
	{
		b3Body_SetLinearVelocity(body, b3Vec3(1.0f, 0.0f, 0.0f));
		b3World_Step(world, 1.0f / 60.0f, 4);
	}

	auto velocity = b3Body_GetLinearVelocity(body);
	auto position = b3Body_GetPosition(body);
	writeln("Reported velocity after stepping: (", velocity.x, ", ", velocity.y, ", ", velocity.z, ")");
	writeln("Position after 1 second: (", position.x, ", ", position.y, ", ", position.z, ")");
	b3DestroyWorld(world);
}

void runGravityCollisionExample()
{
	auto worldDefinition = b3DefaultWorldDef();
	auto world = b3CreateWorld(&worldDefinition);

	auto groundBodyDefinition = b3DefaultBodyDef();
	groundBodyDefinition.position.y = -0.5f;
	auto groundBody = b3CreateBody(world, &groundBodyDefinition);
	auto groundShapeDefinition = b3DefaultShapeDef();
	auto groundBox = b3MakeBoxHull(10.0f, 0.5f, 10.0f);
	b3CreateHullShape(groundBody, &groundShapeDefinition, &groundBox.base);

	auto sphereBodyDefinition = b3DefaultBodyDef();
	sphereBodyDefinition.type = b3_dynamicBody;
	sphereBodyDefinition.position.y = 5.0f;
	auto sphereBody = b3CreateBody(world, &sphereBodyDefinition);
	auto sphereShapeDefinition = b3DefaultShapeDef();
	sphereShapeDefinition.enableContactEvents = true;
	auto sphere = b3Sphere(b3Vec3(0.0f, 0.0f, 0.0f), 0.5f);
	b3CreateSphereShape(sphereBody, &sphereShapeDefinition, &sphere);
	bool contactDetected;
	int contactBeginCount;
	enum timeStep = 1.0f / 60.0f;

	foreach (_; 0 .. 180)
	{
		b3World_Step(world, timeStep, 4);
		auto events = b3World_GetContactEvents(world);
		contactBeginCount += events.beginCount;
		if (events.beginCount > 0)
		{
			contactDetected = true;
			break;
		}
	}

	auto position = b3Body_GetPosition(sphereBody);
	writeln("Gravity/contact-event test: contact=", contactDetected, ", begin events=", contactBeginCount,
		", sphere height=", position.y, " (gravity integrated by Box3D).");
	b3DestroyWorld(world);
}

/// Drops a large grid of boxes/spheres onto a ground slab and reports step timing and solver
/// counters, to stress-test Box3D with a large active body/contact count.
void runStressTestSimulation()
{
	import std.datetime.stopwatch : AutoStart, StopWatch;

	auto worldDefinition = b3DefaultWorldDef();
	worldDefinition.enableSleep = false;
	auto world = b3CreateWorld(&worldDefinition);

	auto groundBodyDefinition = b3DefaultBodyDef();
	auto groundBody = b3CreateBody(world, &groundBodyDefinition);
	auto groundShapeDefinition = b3DefaultShapeDef();
	auto groundBox = b3MakeBoxHull(50.0f, 0.5f, 50.0f);
	b3CreateHullShape(groundBody, &groundShapeDefinition, &groundBox.base);

	enum gridSize = 12;
	enum layerCount = 6;
	enum spacing = 1.1f;

	auto shapeDefinition = b3DefaultShapeDef();
	auto box = b3MakeBoxHull(0.5f, 0.5f, 0.5f);
	auto sphere = b3Sphere(b3Vec3(0.0f, 0.0f, 0.0f), 0.5f);

	int bodyCount;
	foreach (layer; 0 .. layerCount)
	{
		foreach (row; 0 .. gridSize)
		{
			foreach (col; 0 .. gridSize)
			{
				auto bodyDefinition = b3DefaultBodyDef();
				bodyDefinition.type = b3_dynamicBody;
				bodyDefinition.position = b3Vec3(
					(col - 0.5f * (gridSize - 1)) * spacing,
					1.0f + layer * spacing,
					(row - 0.5f * (gridSize - 1)) * spacing);
				auto body = b3CreateBody(world, &bodyDefinition);
				if ((row + col + layer) % 2 == 0)
					b3CreateHullShape(body, &shapeDefinition, &box.base);
				else
					b3CreateSphereShape(body, &shapeDefinition, &sphere);
				++bodyCount;
			}
		}
	}

	enum stepCount = 300;
	enum timeStep = 1.0f / 60.0f;
	double profileStepTotalMs = 0.0;

	auto stopwatch = StopWatch(AutoStart.yes);
	foreach (_; 0 .. stepCount)
	{
		b3World_Step(world, timeStep, 4);
		profileStepTotalMs += b3World_GetProfile(world).step;
	}
	stopwatch.stop();

	auto counters = b3World_GetCounters(world);
	auto elapsedMs = stopwatch.peek.total!"usecs" / 1000.0;
	writeln("Stress test: ", bodyCount, " bodies, ", stepCount, " steps.");
	writeln("  Wall time: ", elapsedMs, " ms total, ", elapsedMs / stepCount, " ms/step (",
		1000.0 / (elapsedMs / stepCount), " steps/sec).");
	writeln("  Box3D-reported solver time: ", profileStepTotalMs / stepCount, " ms/step average.");
	writeln("  Final counters: bodies=", counters.bodyCount, ", shapes=", counters.shapeCount,
		", contacts=", counters.contactCount, ", islands=", counters.islandCount);

	b3DestroyWorld(world);
}

/// Opens a raylib-d window and renders a live Box3D simulation: a static ground slab
/// with a large grid of dynamic boxes and spheres dropped onto it. Closes when the window is closed.
void runRaylibVisualSample()
{
	import raylib;

	enum screenWidth = 1024;
	enum screenHeight = 768;

	InitWindow(screenWidth, screenHeight, "Box3D + raylib-d: falling shapes");
	scope (exit)
		CloseWindow();
	SetTargetFPS(60);

	auto worldDefinition = b3DefaultWorldDef();
	auto world = b3CreateWorld(&worldDefinition);
	scope (exit)
		b3DestroyWorld(world);

	auto groundBodyDefinition = b3DefaultBodyDef();
	auto groundBody = b3CreateBody(world, &groundBodyDefinition);
	auto groundShapeDefinition = b3DefaultShapeDef();
	auto groundBox = b3MakeBoxHull(20.0f, 0.25f, 20.0f);
	b3CreateHullShape(groundBody, &groundShapeDefinition, &groundBox.base);

	enum gridSize = 10;
	enum layerCount = 5;
	enum spacing = 1.1f;

	auto shapeDefinition = b3DefaultShapeDef();
	auto box = b3MakeBoxHull(0.5f, 0.5f, 0.5f);
	auto sphere = b3Sphere(b3Vec3(0.0f, 0.0f, 0.0f), 0.5f);

	b3BodyId[] fallingBodies;
	fallingBodies.reserve(gridSize * gridSize * layerCount);
	foreach (layer; 0 .. layerCount)
	{
		foreach (row; 0 .. gridSize)
		{
			foreach (col; 0 .. gridSize)
			{
				auto bodyDefinition = b3DefaultBodyDef();
				bodyDefinition.type = b3_dynamicBody;
				bodyDefinition.position = b3Vec3(
					(col - 0.5f * (gridSize - 1)) * spacing,
					1.0f + layer * spacing,
					(row - 0.5f * (gridSize - 1)) * spacing);
				auto fallingBody = b3CreateBody(world, &bodyDefinition);
				if ((row + col + layer) % 2 == 0)
					b3CreateHullShape(fallingBody, &shapeDefinition, &box.base);
				else
					b3CreateSphereShape(fallingBody, &shapeDefinition, &sphere);
				fallingBodies ~= fallingBody;
			}
		}
	}

	Camera3D camera;
	camera.position = Vector3(24.0f, 20.0f, 24.0f);
	camera.target = Vector3(0.0f, 2.0f, 0.0f);
	camera.up = Vector3(0.0f, 1.0f, 0.0f);
	camera.fovy = 45.0f;
	camera.projection = CameraProjection.CAMERA_PERSPECTIVE;

	import std.datetime.stopwatch : AutoStart, StopWatch;
	auto physicsWatch = StopWatch(AutoStart.no);
	auto drawWatch = StopWatch(AutoStart.no);
	int frameCount;
	double physicsTotalMs = 0.0;
	double drawTotalMs = 0.0;

	while (!WindowShouldClose())
	{
		physicsWatch.reset();
		physicsWatch.start();
		b3World_Step(world, 1.0f / 60.0f, 4);
		physicsWatch.stop();
		physicsTotalMs += physicsWatch.peek.total!"usecs" / 1000.0;

		drawWatch.reset();
		drawWatch.start();
		BeginDrawing();
		ClearBackground(Colors.RAYWHITE);

		BeginMode3D(camera);
		DrawGrid(40, 1.0f);
		DrawCube(Vector3(0.0f, -0.25f, 0.0f), 40.0f, 0.5f, 40.0f, Colors.LIGHTGRAY);
		DrawCubeWires(Vector3(0.0f, -0.25f, 0.0f), 40.0f, 0.5f, 40.0f, Colors.GRAY);

		foreach (i, fallingBody; fallingBodies)
		{
			auto position = b3Body_GetPosition(fallingBody);
			auto drawPosition = Vector3(position.x, position.y, position.z);
			if (i % 2 == 0)
			{
				DrawCube(drawPosition, 1.0f, 1.0f, 1.0f, Colors.SKYBLUE);
				DrawCubeWires(drawPosition, 1.0f, 1.0f, 1.0f, Colors.DARKBLUE);
			}
			else
				DrawSphere(drawPosition, 0.5f, Colors.MAROON);
		}
		EndMode3D();

		DrawFPS(10, 10);
		DrawText(TextFormat("Box3D bodies: %d - close window to continue", cast(int) fallingBodies.length),
			10, 40, 20, Colors.DARKGRAY);
		EndDrawing();
		drawWatch.stop();
		drawTotalMs += drawWatch.peek.total!"usecs" / 1000.0;

		if (++frameCount % 60 == 0)
		{
			writeln("DEBUG frame ", frameCount, ": physics=", physicsTotalMs / frameCount,
				"ms/frame, draw+present=", drawTotalMs / frameCount, "ms/frame, raylib FPS=", GetFPS());
		}
	}
}

