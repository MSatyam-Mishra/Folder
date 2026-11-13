import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;
import 'package:folders/features/sidebar/model/category_model.dart';
import 'package:folders/features/sidebar/widgets/category_card.dart';
import 'package:flutter/material.dart';


class CategoryGrid extends StatelessWidget {
  const CategoryGrid({super.key});

  @override
  Widget build(BuildContext context) {
    // This is our placeholder data for now.
    final List<Category> categories = [
      Category(icon: LucideIcons.image, name: 'Photos', fileCount: 926, color: Colors.purple.shade300),
      Category(icon: LucideIcons.clapperboard, name: 'Video', fileCount: 54, color: Colors.red.shade300),
      Category(icon: LucideIcons.music, name: 'Audio', fileCount: 15, color: Colors.orange.shade300),
      Category(icon: LucideIcons.fileText, name: 'Documents', fileCount: 29, color: Colors.blue.shade300),
      Category(icon: LucideIcons.lock, name: 'Vault', fileCount: 5, color: Colors.teal.shade300),
      Category(icon: LucideIcons.archive, name: 'Archives', fileCount: 1, color: Colors.brown.shade300),
      Category(icon: LucideIcons.download, name: 'Downloads', fileCount: 20, color: Colors.green.shade300),
    ];

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: GridView.builder(
        shrinkWrap: true, // Important for GridView inside a SingleChildScrollView
        physics: const NeverScrollableScrollPhysics(), // GridView will scroll with the parent
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2, // 2 columns
          crossAxisSpacing: 16,
          mainAxisSpacing: 16,
          childAspectRatio: 1.1, // Adjust for the card's height
        ),
        itemCount: categories.length,
        itemBuilder: (context, index) {
          return CategoryCard(category: categories[index]);
        },
      ),
    );
  }
}